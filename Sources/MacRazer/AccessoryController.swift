// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import Foundation

/// Every Razer accessory (`RazerAccessories`) plugged in next to the mouse, one
/// `AccessoryController` each. Separate from `MouseController` on purpose: their own
/// devices, their own queues, and nothing they do can change which device the mouse side picks.
///
/// Threading follows `MouseController`: device IO on serial queues, `@Published` state on
/// the main queue.
final class Accessories: ObservableObject, @unchecked Sendable {
    static let shared = Accessories()

    /// The accessories plugged in, in a stable order (`RazerAccessories.controlInterfaceIndices`).
    @Published private(set) var connected: [AccessoryController] = []
    @Published private(set) var synapseRunning = false {
        didSet { for accessory in connected { accessory.synapseRunning = synapseRunning } }
    }

    /// The mouse's lighting as MacRazer last set it, for "Follow mouse". Set by the app
    /// delegate; nil in previews and tests.
    var mouseLighting: (() -> AccessoryLighting?)? {
        didSet { for accessory in connected { accessory.mouseLighting = mouseLighting } }
    }

    private let scanQueue = DispatchQueue(label: "MacRazer.accessories")
    private var observers: [NSObjectProtocol] = []
    /// Each accessory's changes, passed on as this object's own, so a view that watches the
    /// list redraws when one card's lighting changes. Main thread.
    private var forwarding: [AccessoryController.ID: AnyCancellable] = [:]

    func start() {
        refreshSynapse()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshSynapse()
            })
        }
        // Synapse may put its own colours back on a wake; ours go back on after it.
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                for accessory in self?.connected ?? [] { accessory.reapplyOverSynapse() }
            }
        })
        rescan()
    }

    /// Look for accessories again: on launch, after each Razer plug event, and each time the
    /// popover opens (to re-read brightness, which the keys on a keyboard change).
    /// `reapply: false` after a failed write, so an accessory that keeps refusing can't loop
    /// write → rescan → reapply → write.
    func rescan(reapply: Bool = true) {
        scanQueue.async { [weak self] in
            let found = HIDDevice.accessoryControlInterfaces().compactMap { device -> FoundAccessory? in
                guard let info = RazerAccessories.info(pid: HIDDevice.productID(of: device)) else { return nil }
                return FoundAccessory(id: .init(pid: info.pid, locationID: HIDDevice.locationID(of: device)),
                                      info: info, device: device)
            }
            DispatchQueue.main.async { self?.apply(found, reapply: reapply) }
        }
    }

    /// Main thread. Keeps the controller of a unit still plugged in (its pending writes and
    /// all), makes one for a new unit, and lets go of the rest.
    private func apply(_ found: [FoundAccessory], reapply: Bool) {
        let existing = Dictionary(uniqueKeysWithValues: connected.map { ($0.id, $0) })
        let next = found.map { unit -> AccessoryController in
            let accessory = existing[unit.id] ?? makeController(unit.id, unit.info)
            accessory.attach(unit.device, reapply: reapply)
            return accessory
        }
        let kept = Set(next.map(\.id))
        for gone in connected where !kept.contains(gone.id) {
            gone.detach()
            forwarding[gone.id] = nil
        }
        if next.map(\.id) != connected.map(\.id) { connected = next }
    }

    private func makeController(_ id: AccessoryController.ID, _ info: RazerAccessoryInfo) -> AccessoryController {
        let accessory = AccessoryController(id: id, info: info)
        accessory.synapseRunning = synapseRunning
        accessory.mouseLighting = mouseLighting
        accessory.onLost = { [weak self] in self?.rescan(reapply: false) }
        forwarding[id] = accessory.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        return accessory
    }

    /// Every accessory with "Follow mouse" on takes the mouse's lighting.
    func followMouse() {
        for accessory in connected { accessory.followMouse() }
    }

    func accessory(_ id: AccessoryController.ID) -> AccessoryController? {
        connected.first { $0.id == id }
    }

    private func refreshSynapse() {
        let running = NSWorkspace.shared.runningApplications.contains {
            SynapseDetector.isSynapse(bundleID: $0.bundleIdentifier, name: $0.localizedName)
        }
        if running != synapseRunning { synapseRunning = running }
    }

    // MARK: Previews

    /// For `render-ui`: accessories on screen without any plugged in. `pids` in display order.
    func loadPreviewState(pids: [Int], followsMouse: Set<Int> = [], synapse: Bool = false,
                          wave: Bool = false, useMacRazer: Set<Int> = []) {
        synapseRunning = synapse
        connected = pids.enumerated().compactMap { index, pid in
            guard let info = RazerAccessories.info(pid: pid) else { return nil }
            let accessory = makeController(.init(pid: pid, locationID: index), info)
            accessory.loadPreviewState(followsMouse: followsMouse.contains(pid), wave: wave && info.supports(.wave),
                                       owner: useMacRazer.contains(pid) ? .macRazer : nil)
            return accessory
        }
    }
}

/// One accessory found in a scan. The `IOHIDDevice` crosses from the scan queue to the
/// accessory's own; nothing touches it in between.
private struct FoundAccessory: @unchecked Sendable {
    let id: AccessoryController.ID
    let info: RazerAccessoryInfo
    let device: IOHIDDevice
}

/// The lighting of one Razer accessory plugged in next to the mouse.
final class AccessoryController: ObservableObject, Identifiable, @unchecked Sendable {
    /// One unit: the model and the USB port it's on, so two of the same model are two cards.
    struct ID: Hashable, Sendable {
        let pid: Int
        let locationID: Int
    }

    let id: ID
    let info: RazerAccessoryInfo

    /// What MacRazer last set, with the brightness as last read from the accessory.
    @Published private(set) var lighting = AccessoryLighting.unknown
    /// Lighting sent that the accessory hasn't answered yet. Main thread.
    @Published private var pending = PendingRequest<AccessoryLighting>()
    /// What the accessory will show once its queued writes land: what the next change builds on.
    var latestLighting: AccessoryLighting { pending.value ?? lighting }
    /// Set on a failed write, like `MouseController.lastWriteFailure`, so the slider can snap back.
    @Published private(set) var lastWriteFailure: Date?
    /// Kept by `Accessories`.
    @Published fileprivate(set) var synapseRunning = false

    /// The accessory takes whatever the mouse's lighting is set to. Turning it on matches the
    /// two straight away.
    @Published var followsMouse: Bool {
        didSet {
            if !isPreview { defaults.set(followsMouse, forKey: Self.followsMouseKey(pid: info.pid)) }
            if followsMouse && !oldValue { followMouse() }
        }
    }

    /// Who sets the colours while Synapse runs; nil until the person picks.
    @Published var owner: AccessoryLightingOwner? {
        didSet { if !isPreview { defaults.set(owner?.rawValue, forKey: Self.ownerKey(pid: info.pid)) } }
    }

    /// A `render-ui` preview: its made-up settings must not reach the real app's defaults.
    private var isPreview = false

    /// Per model, like the lighting. A keyboard falls back on the one setting there was
    /// before accessories had a switch each.
    static func followsMouseKey(pid: Int) -> String { "accessoryFollowsMouse.\(pid)" }
    static func ownerKey(pid: Int) -> String { "accessoryLightingOwner.\(pid)" }
    static let legacyFollowsMouseKey = "keyboardFollowsMouse"
    static let legacyOwnerKey = "keyboardLightingOwner"
    /// Still "keyboard": lighting saved before pads joined keeps its key.
    static func lightingKey(pid: Int) -> String { "keyboardLighting.\(pid)" }

    /// Synapse runs and "Use MacRazer" is off (the default): MacRazer leaves the accessory alone.
    var leftToSynapse: Bool { synapseRunning && owner != .macRazer }
    /// MacRazer may write: no Synapse, or "Use MacRazer" is on.
    var canWrite: Bool { !leftToSynapse }

    /// Set by `Accessories`.
    var mouseLighting: (() -> AccessoryLighting?)?
    /// A write failed in a way that suggests the handle is stale. Set by `Accessories`.
    var onLost: (() -> Void)?

    private let defaults: UserDefaults
    private let io: DispatchQueue
    /// `io` queue only.
    private var device: HIDDevice?

    init(id: ID, info: RazerAccessoryInfo, defaults: UserDefaults = .standard) {
        self.id = id
        self.info = info
        self.defaults = defaults
        io = DispatchQueue(label: "MacRazer.accessory.\(info.pid).\(id.locationID)")
        let legacy = info.kind == .keyboard
        followsMouse = defaults.object(forKey: Self.followsMouseKey(pid: info.pid)) as? Bool
            ?? (legacy && defaults.bool(forKey: Self.legacyFollowsMouseKey))
        owner = (defaults.string(forKey: Self.ownerKey(pid: info.pid))
            ?? (legacy ? defaults.string(forKey: Self.legacyOwnerKey) : nil))
            .flatMap(AccessoryLightingOwner.init)
        lighting = Self.storedLighting(pid: info.pid, defaults: defaults) ?? .unknown
    }

    /// Opens the accessory if it isn't open yet, and reads its brightness. A unit opened
    /// afresh gets MacRazer's lighting back while Synapse runs (`reapplyOverSynapse`).
    func attach(_ chosen: IOHIDDevice, reapply: Bool) {
        let found = UncheckedDevice(device: chosen)
        io.async { [weak self] in
            guard let self else { return }
            let isNew = self.device == nil
            if isNew { self.device = try? HIDDevice.open(found.device, as: "\(self.info.kind.rawValue) interface") }
            guard let device = self.device else { return }
            let brightness = try? device.sendWithRetry(RazerCommands.getBrightness(led: self.info.brightnessLed),
                                                       attempts: HIDDevice.defaultAttempts,
                                                       transactionId: self.info.transactionId).arguments[2]
            self.publish {
                if let brightness {
                    self.lighting.brightness = RazerCommands.brightnessPercent(fromRaw: brightness)
                }
                if isNew && reapply { self.reapplyOverSynapse() }
            }
        }
    }

    /// Unplugged: close the handle.
    func detach() {
        io.async { [weak self] in
            self?.device?.close()
            self?.device = nil
        }
    }

    // MARK: Writes

    func setEffect(_ effect: LightingEffect) {
        guard info.supports(effect) else { return }
        var next = latestLighting
        next.effect = effect
        write(next, brightness: false)
    }

    /// Breathing keeps breathing in the new colour; any other effect switches to static.
    func setColor(_ rgb: RGB) {
        var next = latestLighting
        next.effect = (next.effect ?? .staticColor).afterColorPick()
        next.color = rgb
        write(next, brightness: false)
    }

    /// Only while the accessory runs Wave, where the slider is. Goes through `write` like
    /// every other change, so it can't race one already queued.
    func setWaveSpeed(_ speed: UInt8) {
        guard latestLighting.effect == .wave else { return }
        var next = latestLighting
        next.waveSpeed = speed
        write(next, brightness: false)
    }

    func setBrightness(_ percent: Int) {
        var next = latestLighting
        next.brightness = max(0, min(percent, 100))
        write(next, effect: false)
    }

    /// The mouse's lighting, while `followsMouse` is on. The brightness comes along too, so
    /// the two read as one.
    func followMouse() {
        guard followsMouse, let next = mouseLightingHere(), next != latestLighting else { return }
        write(next, brightness: next.brightness != latestLighting.brightness)
    }

    /// The mouse's lighting, as this accessory can show it: a wave on a pad without one runs
    /// as Spectrum, the nearest it has.
    private func mouseLightingHere() -> AccessoryLighting? {
        guard var mouse = mouseLighting?() else { return nil }
        if let effect = mouse.effect, !info.supports(effect) { mouse.effect = .spectrum }
        return mouse
    }

    /// What the accessory should show now: the mouse's lighting while following it, else what
    /// MacRazer last set on it. nil when MacRazer has set nothing to put back.
    private var intendedLighting: AccessoryLighting? {
        if followsMouse, let mouse = mouseLightingHere() { return mouse }
        return latestLighting.effect == nil ? nil : latestLighting
    }

    /// The person picked who sets the colours while Synapse runs. Picking MacRazer puts back
    /// what MacRazer last set, or the mouse's lighting while following it.
    func choose(_ newOwner: AccessoryLightingOwner) {
        owner = newOwner
        if newOwner == .macRazer, let intended = intendedLighting { write(intended) }
    }

    /// After a wake or a reconnect, only while Synapse runs and the person picked MacRazer:
    /// otherwise nothing else changes the accessory, and rewriting would undo the brightness
    /// keys on a keyboard.
    func reapplyOverSynapse() {
        guard synapseRunning, owner == .macRazer, let intended = intendedLighting else { return }
        write(intended)
    }

    /// `effect: false` skips the effect command, `brightness: false` the brightness one. A
    /// colour or effect change leaves the brightness alone: a keyboard's own keys may have
    /// changed it since it was last read, and resending ours would undo them. Putting
    /// MacRazer's lighting back over Synapse sends both.
    private func write(_ next: AccessoryLighting, effect: Bool = true, brightness: Bool = true) {
        guard canWrite else { return }
        let token = pending.begin(next)
        let info = info
        io.async { [weak self] in
            guard let self else { return }
            guard let device = self.device else {
                self.publish { self.pending.finish(token); self.lastWriteFailure = Date() }
                return
            }
            var failure: Error?
            do {
                if effect, let e = next.effect {
                    _ = try device.sendWithRetry(RazerAccessories.report(for: e, color: next.color,
                                                                         waveSpeed: next.waveSpeed ?? WaveSpeed.standard,
                                                                         on: info),
                                                 attempts: HIDDevice.defaultAttempts, transactionId: info.transactionId)
                }
                if brightness {
                    let raw = RazerCommands.brightnessRaw(fromPercent: next.brightness)
                    _ = try device.sendWithRetry(RazerCommands.setBrightness(raw, led: info.brightnessLed),
                                                 attempts: HIDDevice.defaultAttempts, transactionId: info.transactionId)
                }
            } catch {
                failure = error
            }
            let ok = failure == nil
            switch failure {
            case nil:
                break
            case HIDDevice.HIDError.commandFailed?, HIDDevice.HIDError.notSupported?:
                break // the accessory answered and refused: the handle is fine
            default:
                // Most likely the handle outlived a quick unplug and replug: drop it, so the
                // rescan opens the accessory afresh.
                device.close()
                self.device = nil
                self.publish { self.onLost?() }
            }
            self.publish {
                self.pending.finish(token)
                guard ok else { self.lastWriteFailure = Date(); return }
                // Only what this write sent: `next` builds on queued writes that may yet fail.
                var landed = next
                if !effect {
                    landed.effect = self.lighting.effect
                    landed.color = self.lighting.color
                    landed.waveSpeed = self.lighting.waveSpeed
                }
                if !brightness { landed.brightness = self.lighting.brightness }
                self.lighting = landed
                if !self.isPreview { Self.store(landed, pid: info.pid, defaults: self.defaults) }
            }
        }
    }

    // MARK: Storage

    static func storedLighting(pid: Int, defaults: UserDefaults = .standard) -> AccessoryLighting? {
        defaults.data(forKey: lightingKey(pid: pid))
            .flatMap { try? JSONDecoder().decode(AccessoryLighting.self, from: $0) }
    }

    static func store(_ lighting: AccessoryLighting, pid: Int, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(lighting) {
            defaults.set(data, forKey: lightingKey(pid: pid))
        }
    }

    private func publish(_ block: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    // MARK: Previews

    /// For `render-ui` and tests: an accessory on screen without one plugged in.
    func loadPreviewState(followsMouse: Bool = false, synapse: Bool = false, wave: Bool = false,
                          owner: AccessoryLightingOwner? = nil) {
        isPreview = true
        let red = RGB(r: 0xFF, g: 0x00, b: 0x00), blue = RGB(r: 0x00, g: 0x60, b: 0xFF)
        lighting = AccessoryLighting(effect: wave ? .wave : .staticColor,
                                     color: info.kind == .keyboard ? red : blue,
                                     brightness: info.kind == .keyboard ? 100 : 80)
        if synapse { synapseRunning = true }
        self.followsMouse = followsMouse
        self.owner = owner
    }
}

/// An `IOHIDDevice` handed to an accessory's own queue.
private struct UncheckedDevice: @unchecked Sendable {
    let device: IOHIDDevice
}

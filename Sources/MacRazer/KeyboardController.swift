// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Foundation

/// The backlight of a Razer keyboard plugged in next to the mouse (`RazerKeyboards`).
/// Separate from `MouseController` on purpose: its own device, its own queue, and nothing
/// it does can change which device the mouse side picks.
///
/// Threading follows `MouseController`: device IO on the serial `io` queue, `@Published`
/// state on the main queue.
final class KeyboardController: ObservableObject, @unchecked Sendable {
    static let shared = KeyboardController()

    struct Keyboard: Equatable {
        let pid: Int
        let name: String
        let verified: Bool
    }

    /// The keyboard in use, or nil when none `RazerKeyboards` knows is plugged in.
    @Published private(set) var keyboard: Keyboard?
    /// What MacRazer last set, with the brightness as last read from the keyboard.
    @Published private(set) var lighting = KeyboardLighting.unknown
    /// Set on a failed write, like `MouseController.lastWriteFailure`, so the slider can snap back.
    @Published private(set) var lastWriteFailure: Date?
    @Published private(set) var synapseRunning = false

    /// The keyboard takes whatever the mouse's lighting is set to.
    @Published var followsMouse: Bool = UserDefaults.standard.bool(forKey: KeyboardController.followsMouseKey) {
        didSet { if !isPreview { UserDefaults.standard.set(followsMouse, forKey: Self.followsMouseKey) } }
    }

    /// Who sets the colours while Synapse runs; nil until the person picks.
    @Published var owner: KeyboardLightingOwner? =
        UserDefaults.standard.string(forKey: KeyboardController.ownerKey).flatMap(KeyboardLightingOwner.init) {
        didSet { if !isPreview { UserDefaults.standard.set(owner?.rawValue, forKey: Self.ownerKey) } }
    }

    /// A `render-ui` preview: its made-up settings must not reach the real app's defaults.
    private var isPreview = false

    static let followsMouseKey = "keyboardFollowsMouse"
    static let ownerKey = "keyboardLightingOwner"
    private static func lightingKey(pid: Int) -> String { "keyboardLighting.\(pid)" }

    /// Synapse runs and "Use MacRazer" is off (the default): MacRazer leaves the keyboard alone.
    var leftToSynapse: Bool { synapseRunning && owner != .macRazer }
    /// MacRazer may write: no Synapse, or "Use MacRazer" is on.
    var canWrite: Bool { !leftToSynapse }

    /// The mouse's lighting as MacRazer last set it, for "Also light the keyboard". Set by
    /// the app delegate; nil in previews and tests.
    var mouseLighting: (() -> KeyboardLighting?)?

    private let io = DispatchQueue(label: "MacRazer.keyboard")
    /// `io` queue only.
    private var device: HIDDevice?
    private var info: RazerKeyboardInfo?
    private var observers: [NSObjectProtocol] = []

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.reapplyOverSynapse() }
        })
        rescan()
    }

    /// Look for a keyboard again: on launch and after each Razer plug event.
    func rescan() {
        io.async { [weak self] in self?.rescanSync() }
    }

    /// `io` queue only. A different unit (another PID or port) is opened in place of the one
    /// held; the same one is kept, unless a write through it has failed since.
    /// `reapply: false` after a failed write, so a keyboard that keeps refusing can't loop
    /// write → rescan → reapply → write.
    private func rescanSync(reapply: Bool = true) {
        guard let chosen = HIDDevice.keyboardControlInterface(),
              let found = RazerKeyboards.info(pid: HIDDevice.productID(of: chosen)) else {
            device?.close()
            device = nil
            info = nil
            publish { self.keyboard = nil }
            return
        }
        let location = HIDDevice.locationID(of: chosen)
        let isNew = device == nil || found.pid != info?.pid || location != device?.locationID
        if isNew {
            device?.close()
            device = try? HIDDevice.open(chosen, as: "keyboard interface")
            info = device == nil ? nil : found
        }
        guard let device, let info else {
            publish { self.keyboard = nil }
            return
        }
        let brightness = try? device.sendWithRetry(RazerCommands.getBrightness(led: RazerKeyboards.led),
                                                   attempts: HIDDevice.defaultAttempts,
                                                   transactionId: info.transactionId).arguments[2]
        var stored = Self.storedLighting(pid: info.pid) ?? .unknown
        if let brightness { stored.brightness = RazerCommands.brightnessPercent(fromRaw: brightness) }
        let keyboard = Keyboard(pid: info.pid, name: info.name, verified: info.verified)
        let current = stored
        publish {
            self.keyboard = keyboard
            self.lighting = current
            if isNew && reapply { self.reapplyOverSynapse() }
        }
    }

    // MARK: Writes

    func setEffect(_ effect: LightingEffect) {
        var next = lighting
        next.effect = effect
        write(next, brightness: false)
    }

    func setStaticColor(_ rgb: RGB) {
        var next = lighting
        next.effect = .staticColor
        next.color = rgb
        write(next, brightness: false)
    }

    func setBrightness(_ percent: Int) {
        var next = lighting
        next.brightness = max(0, min(percent, 100))
        write(next, effect: false)
    }

    /// The mouse's lighting, while `followsMouse` is on. The brightness comes along too, so
    /// the two read as one.
    func followMouse() {
        guard followsMouse, let next = mouseLighting?(), next != lighting else { return }
        write(next, brightness: next.brightness != lighting.brightness)
    }

    /// What the keyboard should show now: the mouse's lighting while following it, else what
    /// MacRazer last set on the keyboard. nil when MacRazer has set nothing to put back.
    private var intendedLighting: KeyboardLighting? {
        if followsMouse, let mouse = mouseLighting?() { return mouse }
        return lighting.effect == nil ? nil : lighting
    }

    /// The person picked who sets the colours while Synapse runs. Picking MacRazer puts back
    /// what MacRazer last set, or the mouse's lighting while following it.
    func choose(_ newOwner: KeyboardLightingOwner) {
        owner = newOwner
        if newOwner == .macRazer, let intended = intendedLighting { write(intended) }
    }

    /// After a wake or a reconnect, only while Synapse runs and the person picked MacRazer:
    /// otherwise nothing else changes the keyboard, and rewriting would undo the brightness
    /// keys on the keyboard itself.
    private func reapplyOverSynapse() {
        guard synapseRunning, owner == .macRazer, keyboard != nil, let intended = intendedLighting else { return }
        write(intended)
    }

    /// `effect: false` skips the effect command, `brightness: false` the brightness one. A
    /// colour or effect change leaves the brightness alone: the keyboard's own keys may have
    /// changed it since it was last read, and resending ours would undo them. Putting
    /// MacRazer's lighting back over Synapse sends both.
    private func write(_ next: KeyboardLighting, effect: Bool = true, brightness: Bool = true) {
        guard canWrite else { return }
        io.async { [weak self] in
            guard let self else { return }
            guard let device = self.device, let info = self.info else {
                self.publish { self.lastWriteFailure = Date() }
                return
            }
            var failure: Error?
            do {
                if effect, let e = next.effect {
                    _ = try device.sendWithRetry(RazerKeyboards.report(for: e, color: next.color),
                                                 attempts: HIDDevice.defaultAttempts, transactionId: info.transactionId)
                }
                if brightness {
                    let raw = RazerCommands.brightnessRaw(fromPercent: next.brightness)
                    _ = try device.sendWithRetry(RazerCommands.setBrightness(raw, led: RazerKeyboards.led),
                                                 attempts: HIDDevice.defaultAttempts, transactionId: info.transactionId)
                }
            } catch {
                failure = error
            }
            let ok = failure == nil
            switch failure {
            case nil:
                Self.store(next, pid: info.pid)
            case HIDDevice.HIDError.commandFailed?, HIDDevice.HIDError.notSupported?:
                break // the keyboard answered and refused: the handle is fine
            default:
                // Most likely the handle outlived a quick unplug and replug: drop it, so the
                // rescan opens the keyboard afresh.
                device.close()
                self.device = nil
                self.rescanSync(reapply: false)
            }
            self.publish {
                guard ok else { self.lastWriteFailure = Date(); return }
                self.lighting = next
            }
        }
    }

    // MARK: Synapse

    private func refreshSynapse() {
        let running = NSWorkspace.shared.runningApplications.contains {
            SynapseDetector.isSynapse(bundleID: $0.bundleIdentifier, name: $0.localizedName)
        }
        if running != synapseRunning { synapseRunning = running }
    }

    // MARK: Storage

    private static func storedLighting(pid: Int) -> KeyboardLighting? {
        UserDefaults.standard.data(forKey: lightingKey(pid: pid))
            .flatMap { try? JSONDecoder().decode(KeyboardLighting.self, from: $0) }
    }

    private static func store(_ lighting: KeyboardLighting, pid: Int) {
        if let data = try? JSONEncoder().encode(lighting) {
            UserDefaults.standard.set(data, forKey: lightingKey(pid: pid))
        }
    }

    private func publish(_ block: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    // MARK: Previews

    /// For `render-ui keyboard`: a keyboard on screen without one plugged in.
    func loadPreviewState(followsMouse: Bool = false, synapse: Bool = false) {
        isPreview = true
        keyboard = Keyboard(pid: 0x022A, name: "Razer Cynosa Chroma", verified: true)
        lighting = KeyboardLighting(effect: .staticColor, color: RGB(r: 0xFF, g: 0x00, b: 0x00), brightness: 100)
        synapseRunning = synapse
        self.followsMouse = followsMouse
        owner = nil
    }
}

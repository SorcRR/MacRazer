// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import Combine
import AppKit

/// Owns the HID device for the app's lifetime and exposes observable state to SwiftUI.
/// All HID IO runs on a serial background queue (the calls block with sleeps); published
/// state is updated on the main queue.
/// `@unchecked Sendable`: state is accessed under a strict discipline — `device` only on the
/// `io` queue, `@Published` properties only on the main queue (via `publish`).
final class MouseController: ObservableObject, @unchecked Sendable {
    @Published private(set) var connected = false
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var charging = false
    @Published private(set) var dpi: Int = 0
    @Published private(set) var pollRate: Int = 0
    @Published private(set) var brightness: Int = 100 // percent
    @Published private(set) var dpiStages: [Int] = [] // the mouse's configured DPI presets
    @Published private(set) var timeEstimate: String?
    /// Snapshots of `io`-queue-owned history, republished on the main queue for the usage graph.
    @Published private(set) var batterySamples: [BatterySample] = []
    @Published private(set) var dischargeRatePerHour: Double?
    @Published private(set) var cycleStartedAt: Date?
    @Published private(set) var cycleStartedPercent: Int?
    @Published private(set) var pastCycles: [ChargeCycleSummary] = []
    @Published private(set) var averageCycleHours: Double?
    @Published private(set) var statusText = "…"
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    /// Name of the connected Razer mouse (from its USB product string), or nil if none present.
    @Published private(set) var deviceName: String?
    /// Whether the connected model's control protocol is verified (Cobra family).
    @Published private(set) var deviceSupported = true
    /// Whether the connected mouse has a battery (wired-only mice don't → hide battery UI).
    @Published private(set) var deviceHasBattery = true
    /// Whether the connected mouse has RGB lighting (e.g. the Atheris has none → hide it).
    @Published private(set) var deviceHasLighting = true
    /// Max settable DPI for the connected model (drives the slider range).
    @Published private(set) var deviceMaxDPI = 26000
    /// Bumped whenever a user-initiated device write fails, so the UI can snap its
    /// optimistic slider state back to the real values (the values themselves don't change
    /// on a failed write, so no other `@Published` transition fires).
    @Published private(set) var lastWriteFailure: Date?
    /// Product ID of the connected mouse (nil when none) — drives feature gating.
    @Published private(set) var deviceID: Int?
    /// Stable per-unit key (serial number if available, else PID) — drives per-device settings.
    @Published private(set) var deviceKey: String?
    /// Name of a Razer mouse seen on Bluetooth while we can't reach one over USB. Bluetooth
    /// doesn't expose Razer's control protocol, so this drives a "switch to 2.4GHz / USB" hint.
    @Published private(set) var bluetoothMouseName: String?
    private var ioHasBattery = true // io-queue mirror of deviceHasBattery

    /// Saved DPI/poll/lighting/button-remap presets for the connected mouse, and which one (if
    /// any) currently matches the live config. Loaded/swapped alongside `deviceKey` in
    /// `ensureDevice()`, same as the battery history.
    @Published private(set) var profiles: [MouseProfile] = []
    @Published private(set) var activeProfileID: UUID?

    /// User preference: show the battery % beside the menu bar icon (persisted).
    @Published var showPercentInMenuBar: Bool = (UserDefaults.standard.object(forKey: "showPercentInMenuBar") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(showPercentInMenuBar, forKey: "showPercentInMenuBar")
            updateStatusText()
        }
    }

    private let io = DispatchQueue(label: "com.macrazer.hid")
    private var device: HIDDevice?
    private var pollTimer: Timer?
    private var history = BatteryHistory(deviceKey: "default")
    private var cycleHistory = ChargeCycleHistory(deviceKey: "default")
    private var historyKey: String? // device the current history belongs to
    /// Learned per-percent discharge curve — only set for models `RazerDevices` covers (see
    /// `dischargeCurveModelKey`); nil leaves every other mouse on the generic rate estimate.
    private var curveModel: DischargeCurveModel?
    private var curveModelKey: String?
    /// Suppresses connect/disconnect sounds until the first poll establishes a baseline.
    private var hasBaseline = false
    /// io-queue only: outcome of the most recent read, and a debounce count so a single
    /// transient wireless timeout doesn't flap the UI to "offline".
    private var lastReadOK = false
    private var consecutiveFailures = 0
    /// True once we've read a real (non-zero) battery value; false right after a reconnect
    /// while the device is still settling. Drives fast re-polling until it's ready.
    private var batteryReady = false
    private var lastGoodPercent: Int?  // last trusted reading, for sanity-checking jumps
    private var batteryRejects = 0     // how many implausible post-reconnect readings we've skipped
    /// True once a not-charging→charging transition has been seen but not yet confirmed on a
    /// second consecutive poll (see the charging-status read above).
    private var pendingChargeConfirm = false

    // Adaptive poll cadence: react quickly while offline (to catch reconnects), relax when up.
    private let pollWhenConnected: TimeInterval = 15
    private let pollWhenOffline: TimeInterval = 4

    func start() {
        wireHistory()
        refreshAll()
        scheduleNextPoll(after: pollWhenOffline)
    }

    /// Hooks `history` to log finished discharge cycles into `cycleHistory` and per-interval
    /// dwell time into `curveModel`, and republishes a snapshot for the view. Re-run whenever
    /// `history`/`cycleHistory` are swapped for a new device.
    private func wireHistory() {
        history.onCycleFinished = { [weak self] samples in
            self?.cycleHistory.recordFinishedCycle(samples: samples)
            // The cycle ended, so whatever dwell the curve model had open at the current
            // percent will never complete — drop it so it can't skew a later cycle's mean.
            self?.curveModel?.observationInterrupted()
            guard let self else { return }
            let cycles = self.cycleHistory.cycles
            let avg = self.cycleHistory.averageCycleDuration.map { $0 / 3600 }
            self.publish { self.pastCycles = cycles; self.averageCycleHours = avg }
        }
        // Reads `self.curveModel` dynamically each call, so it stays correct even when only
        // `curveModel` (not `history`) changes — no separate rewiring needed for that case.
        history.onInterval = { [weak self] from, to, duration in
            self?.curveModel?.record(fromPercent: from, toPercent: to, duration: duration)
        }
        history.onObservationGap = { [weak self] in
            self?.curveModel?.observationInterrupted()
        }
    }

    /// Self-rescheduling poll loop. Scheduled on the common run-loop modes so it keeps firing
    /// even while the menu/popover is being tracked.
    private func scheduleNextPoll(after interval: TimeInterval) {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.pollTick()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func pollTick() {
        io.async { [weak self] in
            guard let self else { return }
            self.readBatterySync()
            // Poll fast whenever the last read failed OR the battery isn't ready yet (just
            // reconnected), so we confirm a disconnect, catch a reconnect, and resolve the
            // real % quickly.
            let next = (self.lastReadOK && self.batteryReady) ? self.pollWhenConnected : self.pollWhenOffline
            self.publish { self.scheduleNextPoll(after: next) }
        }
    }

    // MARK: - Reads

    /// Battery only — used by the background timer (no spinner).
    func refreshBattery() {
        io.async { [weak self] in self?.readBatterySync() }
    }

    /// Main-thread only (timer/popover callbacks): prevents the 2s popover timer from
    /// stacking reads while one is still grinding through the retry ladder — with a mouse
    /// that answers slowly (or a dongle answering with stale reports), each read can take
    /// seconds, and unconditionally enqueueing every tick would grow the serial io queue's
    /// backlog without bound, delaying user writes by minutes.
    private var settingsReadQueued = false

    /// Settings (DPI + polling) only — no spinner. Call on the main thread.
    func refreshSettings() {
        guard !settingsReadQueued else { return }
        settingsReadQueued = true
        io.async { [weak self] in
            guard let self else { return }
            self.readSettingsSync()
            self.publish { self.settingsReadQueued = false }
        }
    }

    private var settingsTimer: Timer?

    /// Called when the popover shows/hides. While it's open we re-read DPI/polling every
    /// couple of seconds so on-mouse changes (e.g. the DPI-cycle button) reflect live.
    func setPopoverVisible(_ visible: Bool) {
        settingsTimer?.invalidate()
        settingsTimer = nil
        guard visible else { return }
        refreshSettings()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshSettings()
        }
        RunLoop.main.add(t, forMode: .common)
        settingsTimer = t
    }

    /// Immediate check triggered by an IOKit plug/unplug event. On a removal we pass
    /// `immediateOffline` so the disconnect shows at once (bypassing the timeout debounce,
    /// since a USB termination is definitive). Also realigns the poll cadence.
    func forceCheck(immediateOffline: Bool) {
        io.async { [weak self] in
            guard let self else { return }
            self.readBatterySync(immediateOffline: immediateOffline)
            let next = (self.lastReadOK && self.batteryReady) ? self.pollWhenConnected : self.pollWhenOffline
            self.publish { self.scheduleNextPoll(after: next) }
        }
    }

    /// Full refresh (battery + settings) with the spinner — used by the refresh button.
    /// Re-reads DPI/poll so on-mouse changes (e.g. middle-button DPI cycling) show up.
    func refreshAll() {
        publish { self.isRefreshing = true }
        io.async { [weak self] in
            guard let self else { return }
            self.readBatterySync()
            self.readSettingsSync()
            // Keep the spinner visible long enough to read as feedback — but pace it on the
            // main queue, never by sleeping the serial io queue (that would delay any queued
            // device command, e.g. a DPI write right after tapping refresh).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.isRefreshing = false }
        }
    }

    /// Runs on `io`.
    private func readBatterySync(immediateOffline: Bool = false) {
        do {
            let dev = try ensureDevice()

            // Battery-less mice (wired-only): use a DPI read as the alive-check; no battery UI.
            if !ioHasBattery {
                do {
                    _ = try dev.sendWithRetry(RazerCommands.getDPI())
                } catch HIDDevice.HIDError.commandFailed, HIDDevice.HIDError.notSupported {
                    // Refused ≠ dead: a failure/not-supported reply proves the link is up,
                    // which is all this check needs (some firmwares may reject this exact
                    // DPI variant while everything else works).
                }
                lastReadOK = true
                consecutiveFailures = 0
                batteryReady = true
                publish {
                    let wasConnected = self.connected
                    self.connected = true
                    self.batteryPercent = nil
                    self.lastError = nil
                    self.updateStatusText()
                    if self.hasBaseline && !wasConnected { Self.playSound(connected: true) }
                    self.hasBaseline = true
                }
                return
            }

            let raw: UInt8
            do {
                raw = try dev.sendWithRetry(RazerCommands.getBatteryLevel()).arguments[1]
            } catch HIDDevice.HIDError.commandFailed, HIDDevice.HIDError.notSupported {
                // The device answered — the link is alive — but refused the command (seen
                // on the HyperSpeed around sleep). Pre-validation builds parsed these
                // replies as all-zeros and took the raw==0 grace path below; keep doing
                // the equivalent rather than flapping to offline with disconnect sounds.
                raw = 0
            }
            lastReadOK = true
            consecutiveFailures = 0

            // A raw 0 means "connected but battery not ready yet" — common right after a
            // reconnect/wake while the dongle re-probes. Don't display a bogus 0%: keep the
            // last known value, mark not-ready so we keep polling fast, and bail.
            guard raw != 0 else {
                batteryReady = false
                publish {
                    let wasConnected = self.connected
                    self.connected = true
                    self.lastError = nil
                    self.updateStatusText()
                    if self.hasBaseline && !wasConnected { Self.playSound(connected: true) }
                    self.hasBaseline = true
                }
                return
            }

            let pct = RazerCommands.batteryPercent(fromRaw: raw)

            // A reconnect/wake can return a transient garbage value (e.g. 0xFF → 100%) before
            // settling — but a wild jump is implausible at any time (battery can't swing >20%
            // between 4-15s polls), so this check stays active even once `batteryReady` is
            // true; otherwise the very first post-reconnect read permanently disables it and a
            // later one-off garbage read (any time) gets trusted as the new baseline outright.
            if let last = lastGoodPercent, abs(pct - last) > 20, batteryRejects < 2 {
                batteryRejects += 1
                publish {
                    let wasConnected = self.connected
                    self.connected = true
                    self.lastError = nil
                    self.updateStatusText()
                    if self.hasBaseline && !wasConnected { Self.playSound(connected: true) }
                    self.hasBaseline = true
                }
                return
            }
            batteryRejects = 0
            lastGoodPercent = pct

            var charging = false
            if let cResp = try? dev.sendWithRetry(RazerCommands.getChargingStatus()) {
                charging = cResp.arguments[1] != 0
            }
            // A reconnect/wake can return a one-off garbage charging byte just like it can a
            // garbage percent (see the wild-jump guard above) — but here, acting on a false
            // positive destructively resets the whole discharge history. Require the rising
            // edge (not-charging → charging) to be confirmed on a second consecutive poll
            // before trusting it; dropping back to false is acted on immediately since that
            // direction can't trigger the destructive reset. The unconfirmed first tick isn't
            // logged at all: if the report is real, the sample belongs to the charge session
            // and would skew the finished cycle's end; if it's garbage, one skipped tick is free.
            let isCharging = charging && pendingChargeConfirm
            let skipHistoryTick = charging && !pendingChargeConfirm
            pendingChargeConfirm = charging
            if !skipHistoryTick { history.record(percent: pct, charging: isCharging) }
            let estimate = isCharging ? "Charging" : history.estimateString(currentPercent: pct, curveModel: curveModel)
            let snap = historySnapshot()
            batteryReady = true
            publish {
                let wasConnected = self.connected
                self.connected = true
                self.batteryPercent = pct
                self.charging = isCharging
                self.timeEstimate = estimate
                self.batterySamples = snap.samples
                self.dischargeRatePerHour = snap.rate
                self.cycleStartedAt = snap.cycleStart
                self.cycleStartedPercent = snap.cycleStartPct
                self.lastError = nil
                self.bluetoothMouseName = nil
                self.updateStatusText()
                if self.hasBaseline && !wasConnected { Self.playSound(connected: true) }
                self.hasBaseline = true
            }
        } catch {
            device?.close() // release the user client now rather than at CF-dealloc time
            device = nil    // drop the handle so we reopen next tick
            lastReadOK = false
            batteryReady = false // force the reconnect freshness check next time
            pendingChargeConfirm = false // don't let a stale pending confirm carry across a drop
            consecutiveFailures += 1
            // Require two consecutive failures before declaring offline — the wireless link
            // throws the odd transient timeout that shouldn't flap the UI or fire a sound.
            // An IOKit removal event (immediateOffline) is definitive, so skip the debounce.
            let declareOffline = immediateOffline || consecutiveFailures >= 2
            let errText = String(describing: error)
            // No Razer mouse present at all (vs. present-but-asleep timeout).
            let gone: Bool = { if case HIDDevice.HIDError.notFound = error { return true }; return false }()
            FileHandle.standardError.write(Data("[MacRazer] battery read failed (\(consecutiveFailures)): \(errText)\n".utf8))
            guard declareOffline else { return }
            // Can't reach a Razer mouse over USB — is one sitting on Bluetooth instead? (Razer's
            // control protocol isn't exposed over BT, so that's the likely cause of "offline".)
            let btName = HIDDevice.bluetoothRazerMouseName()
            publish {
                let wasConnected = self.connected
                self.connected = false
                self.lastError = errText
                self.bluetoothMouseName = btName
                if gone { self.deviceName = nil; self.deviceID = nil; self.deviceKey = nil }
                self.updateStatusText()
                if self.hasBaseline && wasConnected { Self.playSound(connected: false) }
                self.hasBaseline = true
            }
        }
    }

    /// Subtle system sound on a connection-state change. "Pop" pairs with "Submarine" —
    /// both soft and rounded. (System sounds live in /System/Library/Sounds; swap the names
    /// here to taste — e.g. "Bottle", "Tink", "Hero" for connect.)
    private static let connectSound = NSSound.Name("Pop")
    private static let disconnectSound = NSSound.Name("Submarine")
    private static func playSound(connected: Bool) {
        NSSound(named: connected ? connectSound : disconnectSound)?.play()
    }

    /// Runs on `io`. Per-feature errors (failure/not-supported — e.g. no brightness on the
    /// Atheris) skip just that value, so the others still update; link-level errors
    /// (timeouts, stale reports) abort the remaining reads — grinding three more full retry
    /// ladders against a dead link would occupy the serial queue for seconds and delay any
    /// queued user write. Battery refresh surfaces connection errors; this can fail quietly.
    private func readSettingsSync() {
        guard let dev = try? ensureDevice() else { return }
        var linkDead = false
        func read<T>(_ report: RazerReport, _ parse: (RazerReport) -> T) -> T? {
            guard !linkDead else { return nil }
            do { return parse(try dev.sendWithRetry(report)) }
            catch HIDDevice.HIDError.commandFailed, HIDDevice.HIDError.notSupported {
                return nil // this feature only — the device answered, keep reading others
            } catch {
                linkDead = true
                return nil
            }
        }
        let d = read(RazerCommands.getDPI()) { Int(RazerCommands.parseDPI($0).x) }
        let p = read(RazerCommands.getPollingRate()) { RazerCommands.parsePollingRate($0) }
        let b = read(RazerCommands.getBrightness()) { RazerCommands.brightnessPercent(fromRaw: $0.arguments[2]) }
        let stages = read(RazerCommands.getDPIStages()) { RazerCommands.parseDPIStages($0) } ?? []
        publish {
            if let d { self.dpi = d }
            if let p { self.pollRate = p }
            if let b { self.brightness = b }
            if !stages.isEmpty { self.dpiStages = stages }
        }
    }

    // MARK: - Writes

    // Setters publish (and un-mark the active profile) only when the device write actually
    // succeeded — publishing optimistically would show the new value in the UI while the
    // mouse keeps its old config, and the next settings poll corrects it confusingly.

    func setDPI(_ value: Int) {
        let v = UInt16(max(100, min(value, 45000)))
        io.async { [weak self] in
            guard let self else { return }
            let ok = (try? self.ensureDevice().sendWithRetry(RazerCommands.setDPI(x: v, y: v))) != nil
            self.publish {
                guard ok else { self.lastWriteFailure = Date(); return }
                self.dpi = Int(v); self.clearActiveProfileIfNeeded()
            }
        }
    }

    func setPollRate(_ hz: Int) {
        io.async { [weak self] in
            guard let self else { return }
            let ok = (try? self.ensureDevice().sendWithRetry(RazerCommands.setPollingRate(hz))) != nil
            self.publish {
                guard ok else { self.lastWriteFailure = Date(); return }
                self.pollRate = hz; self.clearActiveProfileIfNeeded()
            }
        }
    }

    func setBrightness(_ percent: Int) {
        let pct = max(0, min(percent, 100))
        io.async { [weak self] in
            guard let self else { return }
            let ok = (try? self.ensureDevice().sendWithRetry(RazerCommands.setBrightness(RazerCommands.brightnessRaw(fromPercent: pct)))) != nil
            self.publish {
                guard ok else { self.lastWriteFailure = Date(); return }
                self.brightness = pct; self.clearActiveProfileIfNeeded()
            }
        }
    }

    func setStatic(_ rgb: RGB) { send(RazerCommands.setStatic(rgb: rgb)) }
    func setSpectrum() { send(RazerCommands.setSpectrum()) }
    func setWave() { send(RazerCommands.setWave()) }
    func setLightingOff() { send(RazerCommands.setNone()) }

    private func send(_ report: RazerReport) {
        io.async { [weak self] in
            guard let self else { return }
            let ok = (try? self.ensureDevice().sendWithRetry(report)) != nil
            self.publish {
                if ok { self.clearActiveProfileIfNeeded() } else { self.lastWriteFailure = Date() }
            }
        }
    }

    // MARK: - Profiles

    private func clearActiveProfileIfNeeded() {
        guard activeProfileID != nil else { return }
        activeProfileID = nil
        if let key = deviceKey { ProfileStore.setActiveProfileID(nil, forDevice: key) }
    }

    /// Called by `ButtonRemapper.onManualChange` — a remap edit made outside `applyProfile`
    /// means the live config no longer matches the active profile.
    func clearActiveProfileIfManuallyChanged() { clearActiveProfileIfNeeded() }

    /// Captures the current live DPI/poll/brightness/lighting + the remapper's button mappings
    /// as a new named profile for the connected mouse.
    func saveCurrentAsProfile(name: String, effect: String, color: RGB, remapper: ButtonRemapper) {
        guard let key = deviceKey else { return }
        let profile = MouseProfile(name: name, dpi: dpi, pollRate: pollRate == 0 ? 1000 : pollRate,
                                    brightness: brightness, effect: effect, color: color,
                                    buttonMappings: remapper.mappings)
        profiles.append(profile)
        ProfileStore.save(profiles, forDevice: key)
        activeProfileID = profile.id
        ProfileStore.setActiveProfileID(profile.id, forDevice: key)
    }

    /// Applies a saved profile's DPI/poll/brightness/lighting and button remaps to the live
    /// mouse. Sends directly on `io` rather than through the public setters: those un-mark
    /// the active profile on every manual change (which used to require a fragile
    /// cross-queue suppression flag here), and publish per-value — whereas an apply should
    /// mark the profile active only if the device actually took the whole config.
    func applyProfile(_ profile: MouseProfile, remapper: ButtonRemapper) {
        guard let key = deviceKey else { return }
        // Button remaps are software-side (no device write) — apply and persist regardless.
        remapper.setMappings(profile.buttonMappings)

        let dpi = UInt16(max(100, min(profile.dpi, 45000)))
        let hz = profile.pollRate == 0 ? 1000 : profile.pollRate
        let brightnessPct = max(0, min(profile.brightness, 100))
        let lighting: RazerReport
        switch profile.effect {
        case "Static": lighting = RazerCommands.setStatic(rgb: profile.color)
        case "Spectrum": lighting = RazerCommands.setSpectrum()
        case "Wave": lighting = RazerCommands.setWave()
        default: lighting = RazerCommands.setNone()
        }

        io.async { [weak self] in
            guard let self else { return }
            guard let dev = try? self.ensureDevice() else {
                self.publish { self.lastWriteFailure = Date() }
                return
            }
            let dpiOK = (try? dev.sendWithRetry(RazerCommands.setDPI(x: dpi, y: dpi))) != nil
            let pollOK = (try? dev.sendWithRetry(RazerCommands.setPollingRate(hz))) != nil
            // Lighting commands only count on models that have lighting — the Atheris
            // (correctly) refuses them, and that must not block its profiles from applying.
            let hasLighting = RazerDevices.hasLighting(pid: dev.productID)
            let brightOK = !hasLighting
                || (try? dev.sendWithRetry(RazerCommands.setBrightness(RazerCommands.brightnessRaw(fromPercent: brightnessPct)))) != nil
            let lightOK = !hasLighting || (try? dev.sendWithRetry(lighting)) != nil
            let allOK = dpiOK && pollOK && brightOK && lightOK
            self.publish {
                if dpiOK { self.dpi = Int(dpi) }
                if pollOK { self.pollRate = hz }
                if hasLighting && brightOK { self.brightness = brightnessPct }
                // The contains-check covers a profile deleted while the writes were in
                // flight — marking it active would persist a dangling id.
                if allOK, self.profiles.contains(where: { $0.id == profile.id }) {
                    self.activeProfileID = profile.id
                    ProfileStore.setActiveProfileID(profile.id, forDevice: key)
                } else {
                    // Partial/failed apply: don't claim the profile is active, and let the
                    // UI snap any optimistic state back to reality.
                    self.lastWriteFailure = Date()
                }
            }
        }
    }

    func renameProfile(_ id: UUID, to newName: String) {
        // Same trim-and-reject-empty rule as profile creation — a whitespace-only commit
        // would leave a blank, unclickable-looking chip on the main page.
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let key = deviceKey,
              let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].name = name
        ProfileStore.save(profiles, forDevice: key)
    }

    func deleteProfile(_ id: UUID) {
        guard let key = deviceKey else { return }
        profiles.removeAll { $0.id == id }
        ProfileStore.save(profiles, forDevice: key)
        if activeProfileID == id {
            activeProfileID = nil
            ProfileStore.setActiveProfileID(nil, forDevice: key)
        }
    }

    /// Populate plausible state for the `render-ui` preview command (no device needed).
    func loadPreviewState() {
        connected = true
        deviceName = "Razer Cobra HyperSpeed"
        deviceID = 0x00DB
        batteryPercent = 72
        charging = false
        dpi = 1600
        pollRate = 1000
        timeEstimate = "~3d 0h left (est.)" // matches BatteryHistory.estimateString's real format
        let now = Date()
        batterySamples = stride(from: 0, through: 28, by: 1).map {
            BatterySample(t: now.addingTimeInterval(Double($0) * -3600), pct: min(100, 2 + $0 * 4))
        }.reversed()
        dischargeRatePerHour = 1.0
        cycleStartedAt = batterySamples.first?.t
        cycleStartedPercent = batterySamples.first?.pct
        pastCycles = (1...6).map { i in
            let end = now.addingTimeInterval(Double(-i) * 86400)
            return ChargeCycleSummary(start: end.addingTimeInterval(-Double(20 + i) * 3600),
                                       end: end, startPercent: 100, endPercent: 5)
        }
        averageCycleHours = 23
        updateStatusText()
        let p1 = MouseProfile(name: "Work", dpi: 1600, pollRate: 1000, brightness: 60,
                               effect: "Static", color: RGB(r: 0x44, g: 0xD6, b: 0x2C), buttonMappings: [:])
        let p2 = MouseProfile(name: "Gaming", dpi: 6400, pollRate: 1000, brightness: 100,
                               effect: "Spectrum", color: RGB(r: 255, g: 0, b: 0), buttonMappings: [:])
        profiles = [p1, p2]
        activeProfileID = p1.id
    }

    /// For the `render-ui offline` preview: keep last-known values but mark disconnected.
    func setPreviewOffline() { connected = false; updateStatusText() }

    /// For the `render-ui bluetooth` preview: a Razer mouse is on Bluetooth, so no USB control
    /// (dongle present, name known, but no live battery/DPI readings).
    func setPreviewBluetooth() {
        connected = false
        batteryPercent = nil
        timeEstimate = nil
        bluetoothMouseName = "Cobra HS"
        updateStatusText()
    }

    // MARK: - Helpers

    /// Writes out the throttled savers' in-memory tail (up to ~30s of samples/curve updates
    /// otherwise dropped on every clean quit). Called from `applicationWillTerminate`.
    /// Best-effort with a short timeout: the serial queue may be mid-poll inside the HID
    /// retry ladder (seconds of sleeps against a flaky dongle), and wedging quit behind
    /// that is worse than losing the tail — the timeout path just matches the old
    /// unclean-quit behavior.
    func flushHistoryToDisk() {
        let done = DispatchSemaphore(value: 0)
        io.async {
            self.history.saveNow()
            self.curveModel?.saveNow()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    /// io-queue only: snapshot of everything the UI derives from `history`, decimated for
    /// display. Shared by the poll path and the device-swap republish so the two can't
    /// drift (e.g. one of them forgetting the decimation).
    private func historySnapshot() -> (samples: [BatterySample], rate: Double?, cycleStart: Date?, cycleStartPct: Int?) {
        (BatteryHistory.decimatedForDisplay(history.samples),
         history.currentRatePerHour,
         history.cycleStartedAt,
         history.cycleStartedPercent)
    }

    /// Must be called on `io`.
    private func ensureDevice() throws -> HIDDevice {
        if let d = device { return d }
        let d = try HIDDevice.open(vendorId: Razer.vendorId) // any Razer mouse
        device = d
        let pid = d.productID
        // Model-scoped (not per-serial) discharge curve, shared across every unit of a covered
        // model so data accumulates faster. Independent of the per-unit `historyKey` swap below
        // since the curve key is the same across both Cobra HyperSpeed PIDs and every serial.
        let newCurveKey = RazerDevices.dischargeCurveModelKey(pid: pid)
        if newCurveKey != curveModelKey {
            curveModelKey = newCurveKey
            curveModel = newCurveKey.map { DischargeCurveModel(modelKey: $0) }
        }
        // Per-unit key: the device's serial number if it reports one, else the PID. Lets two
        // mice of the same model keep separate settings. If the serial probe fails on a
        // reconnect (the wireless link is already known to be flaky) but we already have a
        // serial-keyed history for this session, keep using it instead of falling back to the
        // PID key — that fallback would fragment one mouse's history across two files on every
        // transient serial-read failure rather than just on a genuine device change.
        let serial = (try? d.sendWithRetry(RazerCommands.getSerial())).flatMap { RazerCommands.parseSerial($0) }
        let key = serial ?? historyKey ?? String(format: "%04x", pid)
        // Switch to this mouse's own battery history (per-device file + learned rate).
        if key != historyKey {
            historyKey = key
            history = BatteryHistory(deviceKey: key)
            cycleHistory = ChargeCycleHistory(deviceKey: key)
            wireHistory()
            // A charging debounce pending for the previous mouse must not auto-confirm the new
            // one's first read — that's exactly the unverified-first-read case the debounce
            // exists to guard.
            pendingChargeConfirm = false
            // The curve model is model-scoped and survives this per-unit swap when both
            // units are the same model — but its open dwell belongs to the previous mouse,
            // and the new one's current percent was never watched arriving.
            curveModel?.observationInterrupted()
            // Republish everything derived from history immediately so the usage graph doesn't
            // keep showing the previous mouse's curve until the next poll tick.
            let snap = historySnapshot()
            let cycles = cycleHistory.cycles
            let avg = cycleHistory.averageCycleDuration.map { $0 / 3600 }
            let loadedProfiles = ProfileStore.profiles(forDevice: key)
            let loadedActiveID = ProfileStore.activeProfileID(forDevice: key)
            publish {
                self.batterySamples = snap.samples
                self.dischargeRatePerHour = snap.rate
                self.cycleStartedAt = snap.cycleStart
                self.cycleStartedPercent = snap.cycleStartPct
                self.pastCycles = cycles
                self.averageCycleHours = avg
                self.profiles = loadedProfiles
                self.activeProfileID = loadedActiveID
            }
        }
        let name = d.productName
        let battery = RazerDevices.hasBattery(pid: pid)
        ioHasBattery = battery
        publish {
            self.deviceID = pid
            self.deviceKey = key
            self.deviceName = name
            self.deviceSupported = RazerDevices.fullySupported(pid: pid)
            self.deviceHasBattery = battery
            self.deviceHasLighting = RazerDevices.hasLighting(pid: pid)
            self.deviceMaxDPI = RazerDevices.maxDPI(pid: pid)
        }
        return d
    }

    private func publish(_ block: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func updateStatusText() {
        // No-battery mouse or preference off → show just the mouse icon (no text).
        guard showPercentInMenuBar, deviceHasBattery else { statusText = ""; return }
        guard let p = batteryPercent, connected else { statusText = " —"; return }
        // Single mouse glyph + percentage only — charging is shown inside the popover.
        statusText = " \(p)%"
    }
}

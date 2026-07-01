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

    /// Settings (DPI + polling) only — no spinner.
    func refreshSettings() {
        io.async { [weak self] in self?.readSettingsSync() }
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
            // Keep the spinner visible long enough to read as feedback.
            Thread.sleep(forTimeInterval: 0.35)
            self.publish { self.isRefreshing = false }
        }
    }

    /// Runs on `io`.
    private func readBatterySync(immediateOffline: Bool = false) {
        do {
            let dev = try ensureDevice()

            // Battery-less mice (wired-only): use a DPI read as the alive-check; no battery UI.
            if !ioHasBattery {
                _ = try dev.sendWithRetry(RazerCommands.getDPI())
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

            let bResp = try dev.sendWithRetry(RazerCommands.getBatteryLevel())
            let raw = bResp.arguments[1]
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
            device = nil // drop the handle so we reopen next tick
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

    /// Runs on `io`.
    private func readSettingsSync() {
        do {
            let dev = try ensureDevice()
            let d = Int(RazerCommands.parseDPI(try dev.sendWithRetry(RazerCommands.getDPI())).x)
            let p = RazerCommands.parsePollingRate(try dev.sendWithRetry(RazerCommands.getPollingRate()))
            let b = RazerCommands.brightnessPercent(fromRaw: try dev.sendWithRetry(RazerCommands.getBrightness()).arguments[2])
            // DPI stages are optional (a few models don't expose them) — don't fail the read.
            let stages = (try? dev.sendWithRetry(RazerCommands.getDPIStages())).map { RazerCommands.parseDPIStages($0) } ?? []
            publish { self.dpi = d; self.pollRate = p; self.brightness = b; if !stages.isEmpty { self.dpiStages = stages } }
        } catch {
            // Battery refresh surfaces connection errors; settings read can fail quietly.
        }
    }

    // MARK: - Writes

    func setDPI(_ value: Int) {
        let v = UInt16(max(100, min(value, 45000)))
        io.async { [weak self] in
            guard let self else { return }
            _ = try? self.ensureDevice().sendWithRetry(RazerCommands.setDPI(x: v, y: v))
            self.publish { self.dpi = Int(v); self.clearActiveProfileIfNeeded() }
        }
    }

    func setPollRate(_ hz: Int) {
        io.async { [weak self] in
            guard let self else { return }
            _ = try? self.ensureDevice().sendWithRetry(RazerCommands.setPollingRate(hz))
            self.publish { self.pollRate = hz; self.clearActiveProfileIfNeeded() }
        }
    }

    func setBrightness(_ percent: Int) {
        let pct = max(0, min(percent, 100))
        io.async { [weak self] in
            guard let self else { return }
            _ = try? self.ensureDevice().sendWithRetry(RazerCommands.setBrightness(RazerCommands.brightnessRaw(fromPercent: pct)))
            self.publish { self.brightness = pct; self.clearActiveProfileIfNeeded() }
        }
    }

    func setStatic(_ rgb: RGB) { send(RazerCommands.setStatic(rgb: rgb)) }
    func setSpectrum() { send(RazerCommands.setSpectrum()) }
    func setWave() { send(RazerCommands.setWave()) }
    func setLightingOff() { send(RazerCommands.setNone()) }

    private func send(_ report: RazerReport) {
        io.async { [weak self] in
            guard let self else { return }
            _ = try? self.ensureDevice().sendWithRetry(report)
            self.publish { self.clearActiveProfileIfNeeded() }
        }
    }

    // MARK: - Profiles

    /// Suppressed while `applyProfile` is driving these same setters, so applying a profile
    /// doesn't immediately un-mark itself as active.
    private var isApplyingProfile = false

    private func clearActiveProfileIfNeeded() {
        guard !isApplyingProfile, activeProfileID != nil else { return }
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

    /// Applies a saved profile's DPI/poll/brightness/lighting and button remaps to the live mouse.
    func applyProfile(_ profile: MouseProfile, remapper: ButtonRemapper) {
        guard let key = deviceKey else { return }
        isApplyingProfile = true
        setDPI(profile.dpi)
        setPollRate(profile.pollRate)
        setBrightness(profile.brightness)
        switch profile.effect {
        case "Static": setStatic(profile.color)
        case "Spectrum": setSpectrum()
        case "Wave": setWave()
        default: setLightingOff()
        }
        remapper.setMappings(profile.buttonMappings)
        // The writes above are dispatched async on `io`; flip the suppression flag back off
        // once they've had a chance to land, then set the real active id.
        io.async { [weak self] in
            guard let self else { return }
            self.publish {
                self.isApplyingProfile = false
                self.activeProfileID = profile.id
                ProfileStore.setActiveProfileID(profile.id, forDevice: key)
            }
        }
    }

    func renameProfile(_ id: UUID, to newName: String) {
        guard let key = deviceKey, let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].name = newName
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

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
    private var ioHasBattery = true // io-queue mirror of deviceHasBattery

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
    private var historyKey: String? // device the current history belongs to
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

    // Adaptive poll cadence: react quickly while offline (to catch reconnects), relax when up.
    private let pollWhenConnected: TimeInterval = 15
    private let pollWhenOffline: TimeInterval = 4

    func start() {
        refreshAll()
        scheduleNextPoll(after: pollWhenOffline)
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

            // Right after a reconnect/wake the device can return a transient garbage value
            // (e.g. 0xFF → 100%) before settling. If the first reading jumps wildly from the
            // last trusted value, distrust it once or twice and re-poll fast.
            if !batteryReady, let last = lastGoodPercent, abs(pct - last) > 20, batteryRejects < 2 {
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
            let isCharging = charging
            history.record(percent: pct, charging: isCharging)
            let estimate = isCharging ? "Charging" : history.estimateString(currentPercent: pct)
            batteryReady = true
            publish {
                let wasConnected = self.connected
                self.connected = true
                self.batteryPercent = pct
                self.charging = isCharging
                self.timeEstimate = estimate
                self.lastError = nil
                self.updateStatusText()
                if self.hasBaseline && !wasConnected { Self.playSound(connected: true) }
                self.hasBaseline = true
            }
        } catch {
            device = nil // drop the handle so we reopen next tick
            lastReadOK = false
            batteryReady = false // force the reconnect freshness check next time
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
            publish {
                let wasConnected = self.connected
                self.connected = false
                self.lastError = errText
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
            self.publish { self.dpi = Int(v) }
        }
    }

    func setPollRate(_ hz: Int) {
        io.async { [weak self] in
            guard let self else { return }
            _ = try? self.ensureDevice().sendWithRetry(RazerCommands.setPollingRate(hz))
            self.publish { self.pollRate = hz }
        }
    }

    func setBrightness(_ percent: Int) {
        let pct = max(0, min(percent, 100))
        io.async { [weak self] in
            guard let self else { return }
            _ = try? self.ensureDevice().sendWithRetry(RazerCommands.setBrightness(RazerCommands.brightnessRaw(fromPercent: pct)))
            self.publish { self.brightness = pct }
        }
    }

    func setStatic(_ rgb: RGB) { send(RazerCommands.setStatic(rgb: rgb)) }
    func setSpectrum() { send(RazerCommands.setSpectrum()) }
    func setWave() { send(RazerCommands.setWave()) }
    func setLightingOff() { send(RazerCommands.setNone()) }

    private func send(_ report: RazerReport) {
        io.async { [weak self] in
            _ = try? self?.ensureDevice().sendWithRetry(report)
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
        timeEstimate = "About 3 days remaining"
        updateStatusText()
    }

    /// For the `render-ui offline` preview: keep last-known values but mark disconnected.
    func setPreviewOffline() { connected = false; updateStatusText() }

    // MARK: - Helpers

    /// Must be called on `io`.
    private func ensureDevice() throws -> HIDDevice {
        if let d = device { return d }
        let d = try HIDDevice.open(vendorId: Razer.vendorId) // any Razer mouse
        device = d
        let pid = d.productID
        // Per-unit key: the device's serial number if it reports one, else the PID. Lets two
        // mice of the same model keep separate settings.
        let serial = (try? d.sendWithRetry(RazerCommands.getSerial())).flatMap { RazerCommands.parseSerial($0) }
        let key = serial ?? String(format: "%04x", pid)
        // Switch to this mouse's own battery history (per-device file + learned rate).
        if key != historyKey {
            historyKey = key
            history = BatteryHistory(deviceKey: key)
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

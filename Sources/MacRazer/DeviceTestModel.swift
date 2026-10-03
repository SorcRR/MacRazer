// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import IOKit.hid

/// Drives the device test window: which screen is showing, running each step on the mouse
/// through `MouseController`, and building the report as it goes.
///
/// The steps themselves live in `DeviceTestSteps` and are tested there. This decides only
/// when they run: Identify and Battery read and run by themselves; DPI, polling and lighting
/// change things, so they wait for Run and can be skipped without touching the mouse.
@MainActor
final class DeviceTestModel: ObservableObject {
    enum Stage: Int, Comparable {
        case intro, permission, identify, battery, dpi, polling, lighting, buttons, review
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    /// The stages the progress bar counts.
    static let steps: [Stage] = [.identify, .battery, .dpi, .polling, .lighting, .buttons, .review]

    enum Answer: Equatable {
        case yes, no, unsure
        var asBool: Bool? {
            switch self {
            case .yes: return true
            case .no: return false
            case .unsure: return nil
            }
        }
    }

    /// Why the test can't start at all.
    enum Blocker: Equatable {
        case noMouse
        case bluetoothOnly(String)
    }

    /// When a relaunch for Input Monitoring was asked for, so the test window reopens after
    /// it. A date rather than a flag: a relaunch that fails doesn't terminate, and a flag left
    /// behind would open the test on some unrelated launch days later.
    nonisolated static let resumeKey = "deviceTest.resumeAfterRelaunch"
    nonisolated static let resumeWindow: TimeInterval = 120

    /// Whether this launch is the relaunch the test asked for. Clears the request either way.
    nonisolated static func takeResumeRequest(_ defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        let asked = defaults.object(forKey: resumeKey) as? Date
        defaults.removeObject(forKey: resumeKey)
        guard let asked else { return false }
        return now.timeIntervalSince(asked) >= 0 && now.timeIntervalSince(asked) < resumeWindow
    }

    @Published private(set) var stage: Stage = .intro
    @Published private(set) var running = false {
        didSet {
            guard !running else { return }
            let waiting = idleWaiters
            idleWaiters = []
            waiting.forEach { $0() }
        }
    }
    private var idleWaiters: [() -> Void] = []

    /// Runs `body` once no step is running: now, or when the current one finishes. Quit waits
    /// on this, because a step may have the mouse dark, red or at a test DPI until it ends.
    func whenIdle(_ body: @escaping () -> Void) {
        if running { idleWaiters.append(body) } else { body() }
    }
    @Published private(set) var report: DeviceReport?
    @Published private(set) var blocker: Blocker?
    @Published private(set) var needsRelaunch = false
    @Published var connection: DeviceReport.Connection? {
        didSet { report?.device.connection = connection }
    }
    @Published var maxProbe = false
    @Published var dimmed: Answer? { didSet { foldLightingAnswers() } }
    @Published var turnedRed: Answer? { didSet { foldLightingAnswers() } }
    @Published private(set) var buttonsSeen: [String] = []
    /// Whether the button step could open the mouse to listen. False means it can't hear
    /// presses (no Input Monitoring, or the mouse went away), and the step says so.
    @Published private(set) var listening = false
    @Published var comment = ""
    @Published var credit = ""
    @Published var replyEmail = ""
    @Published private(set) var copied = false
    @Published private(set) var issueOpened = false

    let controller: MouseController
    private let permissions: PermissionsModel
    private var capture: ButtonCapture?
    private var standardId: UInt8 = 0x1F
    private var matrixId: UInt8 = 0x1F
    /// A known model's per-command ids, used as the app's own traffic would.
    private var overrides: [UInt16: UInt8] = [:]
    private var lightSweep: [DeviceProbe.LEDAnswer]?
    private var sessionOpen = false

    init(controller: MouseController, permissions: PermissionsModel) {
        self.controller = controller
        self.permissions = permissions
    }

    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Whether the connected model is already on the verified list. Decides the intro's wording
    /// and, at the end, whether a clean run is a confirmation or a new mouse.
    var isKnownSupported: Bool {
        previewKnown ?? controller.deviceID.map { RazerDevices.fullySupported(pid: $0) } ?? false
    }
    /// Set only by `loadPreview`, to render both intros without a device.
    private var previewKnown: Bool?
    var deviceName: String { report?.device.name ?? controller.deviceName ?? "your mouse" }
    var emailProblem: String? { DeviceReportOutput.emailProblem(replyEmail) }

    // MARK: - Starting

    /// A Razer device with a mouse interface is plugged in by cable or dongle. Listing devices
    /// needs no permission, so this works before Input Monitoring. A mouse interface, not just
    /// the vendor id: with only a Razer keyboard attached, the test would otherwise run on it.
    static var razerMousePresent: Bool {
        !HIDDevice.devices(matching: [
            kIOHIDVendorIDKey as String: Razer.vendorId,
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse,
        ]).isEmpty
    }

    func start() {
        // A window closed mid-step and reopened: that step is still finishing on the device.
        guard !running else { return }
        blocker = nil
        // The app may be controlling the mouse over Bluetooth, even with the dongle plugged in
        // (`MouseController.prefersBluetooth`), but the test needs the USB link.
        guard Self.razerMousePresent, !controller.deviceIsBluetooth else {
            blocker = HIDDevice.bluetoothRazerMouse().map { .bluetoothOnly($0.name) } ?? .noMouse
            return
        }
        guard Self.inputMonitoringGranted else {
            stage = .permission
            return
        }
        begin()
    }

    func grantAccess() {
        permissions.grantInputMonitoring()
        if Self.inputMonitoringGranted { begin() }
    }

    /// Called when the window comes back to the front: the person may have just granted it in
    /// System Settings.
    func recheckAccess() {
        if stage == .permission, !needsRelaunch, Self.inputMonitoringGranted { begin() }
    }

    func openSettings() { permissions.openInputMonitoringSettings() }

    /// macOS applies a fresh Input Monitoring grant to device access only after a relaunch.
    func relaunchAndResume() {
        UserDefaults.standard.set(Date(), forKey: Self.resumeKey)
        permissions.relaunch()
    }

    /// Without Input Monitoring only what macOS lists for anyone can be reported: the product
    /// ID, name and interfaces. Still the first thing needed to add a mouse.
    func continueWithoutAccess() {
        // Nothing more will touch the mouse, so the app's own reads can resume now.
        endSession()
        let (interfaces, control) = HIDDevice.interfaceSummaries(vendorId: Razer.vendorId)
        let product = control.map { interfaces[$0] } ?? interfaces.first
        let pid = product?.productID ?? 0
        report = Self.emptyReport(pid: pid, name: product?.product ?? "Razer mouse",
                                  interfaces: interfaces, control: control,
                                  identify: .init(outcome: .skipped, error: "Input Monitoring wasn't granted."))
        stage = .review
    }

    private func begin() {
        needsRelaunch = false
        if !sessionOpen {
            controller.beginDeviceTest()
            sessionOpen = true
        }
        stage = .identify
        Task { await runIdentify() }
    }

    // MARK: - Steps

    private struct IdentifyResult: Sendable {
        let pid: Int
        let name: String
        let record: DeviceReport.StepRecord<DeviceReport.IdentifyData>
        let sweep: [DeviceProbe.LEDAnswer]?
        let interfaces: [DeviceProbe.Interface]
        let control: Int?
    }

    private func runIdentify() async {
        running = true
        defer { running = false }
        do {
            let result = try await controller.runDeviceTestStep { device -> IdentifyResult in
                let (record, sweep) = DeviceTestSteps.identify(device, registry: RazerDevices.info(pid: device.productID))
                let (interfaces, control) = HIDDevice.interfaceSummaries(vendorId: Razer.vendorId)
                return IdentifyResult(pid: device.productID, name: device.productName, record: record,
                                      sweep: sweep, interfaces: interfaces, control: control)
            }
            let info = RazerDevices.info(pid: result.pid)
            report = Self.emptyReport(pid: result.pid, name: result.name, interfaces: result.interfaces,
                                      control: result.control, identify: result.record)
            report?.registry = info.map(DeviceReport.Registry.init)
            standardId = result.record.data?.standardId ?? info?.transactionId ?? 0x1F
            matrixId = result.record.data?.lightingId ?? standardId
            overrides = info?.transactionOverrides ?? [:]
            lightSweep = result.sweep
            // Known models say how they connect; only an unknown one needs asking.
            switch info?.connection {
            case .wired?: connection = .cable
            case .wirelessDongle?: connection = .dongle
            default: break
            }
        } catch {
            if HIDDevice.errorLooksPermissionDenied(String(describing: error)) {
                // Granted, but macOS hasn't applied it to this process yet.
                needsRelaunch = true
                stage = .permission
            } else {
                blocker = .noMouse
                endSession()
                stage = .intro
            }
        }
    }

    private static func emptyReport(pid: Int, name: String, interfaces: [DeviceProbe.Interface], control: Int?,
                                    identify: DeviceReport.StepRecord<DeviceReport.IdentifyData>) -> DeviceReport {
        DeviceReport(appVersion: AppInfo.displayVersion, macOSVersion: DeviceReport.currentMacOSVersion,
                     device: .init(vendorID: Razer.vendorId, productID: pid, name: name, connection: nil,
                                   interfaces: interfaces, controlInterface: control),
                     registry: nil, identify: identify, battery: .init(), dpi: .init(), polling: .init(),
                     lighting: .init(), buttons: .init(), verdict: nil, comment: nil, credit: nil, replyEmail: nil)
    }

    /// Runs one step over the ids Identify found and stores its record in the report.
    private func run<T>(_ keyPath: WritableKeyPath<DeviceReport, DeviceReport.StepRecord<T>>,
                        _ step: @escaping @Sendable (DeviceProbeChannel) -> DeviceReport.StepRecord<T>) async
    where T: Sendable {
        running = true
        defer { running = false }
        let standard = standardId, matrix = matrixId, overrides = overrides
        let record = try? await controller.runDeviceTestStep { device in
            DeviceTestSteps.recorded(device, standard: standard, matrix: matrix, overrides: overrides, step)
        }
        report?[keyPath: keyPath] = record ?? .init(outcome: .failed, error: "The mouse wasn't reachable.")
    }

    func runBattery() async {
        let expects = report?.registry?.hasBattery
        await run(\.battery) { DeviceTestSteps.battery($0, expectsBattery: expects) }
    }

    func runDPI() async {
        let probe = maxProbe
        await run(\.dpi) { DeviceTestSteps.dpi($0, maxProbe: probe) }
    }

    func runPolling() async { await run(\.polling) { DeviceTestSteps.polling($0) } }

    func runLighting() async {
        let sweep = lightSweep
        let restore = controller.lightingRestoreReport()
        dimmed = nil
        turnedRed = nil
        await run(\.lighting) {
            DeviceTestSteps.lighting($0, sweep: sweep, restoreEffect: restore, seconds: 3)
        }
    }

    private func foldLightingAnswers() {
        guard var record = report?.lighting else { return }
        DeviceTestSteps.answered(dimmed: dimmed?.asBool, turnedRed: turnedRed?.asBool, &record)
        report?.lighting = record
    }

    /// The lighting step can move on once every check that ran has an answer, "not sure"
    /// included.
    var lightingAnswered: Bool {
        guard let data = report?.lighting.data, data.dimShown else { return true }
        return dimmed != nil && (!data.redShown || turnedRed != nil)
    }

    // MARK: - Buttons

    private func startListening() {
        buttonsSeen = []
        let capture = ButtonCapture { [weak self] label in
            Task { @MainActor in self?.saw(label) }
        }
        self.capture = capture
        listening = capture.start(vendorID: Razer.vendorId, productID: report?.device.productID ?? 0)
    }

    private func saw(_ label: String) {
        if !buttonsSeen.contains(label) { buttonsSeen.append(label) }
    }

    private func stopListening() {
        capture?.stop()
        capture = nil
        listening = false
        report?.buttons = .init(outcome: buttonsSeen.isEmpty ? .skipped : .passed,
                                data: .init(seen: buttonsSeen))
    }

    // MARK: - Moving between screens

    func next() {
        guard !running, let target = DeviceTestFlow.next(from: stage) else { return }
        move(to: target)
    }

    func back() {
        guard !running, let target = DeviceTestFlow.back(from: stage, identifyRan: report?.identify.data != nil)
        else { return }
        move(to: target)
    }

    /// The side effects of arriving at or leaving a screen: the button step listens only while
    /// it is showing, and Battery reads itself the first time it appears.
    private func move(to target: Stage) {
        if stage == .buttons { stopListening() }
        stage = target
        switch target {
        case .battery where report?.battery.data == nil: Task { await runBattery() }
        case .buttons: startListening()
        default: break
        }
    }

    // MARK: - Review

    /// The report as it would leave the window now: answers folded in, fields cleaned, and
    /// the verdict worked out.
    func finalReport() -> DeviceReport? {
        guard var report else { return nil }
        report.comment = DeviceReportOutput.cleaned(comment, max: DeviceReportOutput.maxComment, singleLine: false)
        report.credit = DeviceReportOutput.cleaned(credit, max: DeviceReportOutput.maxCredit, singleLine: true)
        report.replyEmail = emailProblem == nil
            ? DeviceReportOutput.cleaned(replyEmail, max: DeviceReportOutput.maxEmail, singleLine: true) : nil
        report.verdict = report.currentVerdict()
        // Every way out carries the same report, so the one sized for Send.
        return DeviceReportOutput.fitted(report)
    }

    /// Copies the report without the reply email: a clipboard tends to end up pasted somewhere
    /// public, and the address is only for the maintainer.
    func copyReport() {
        guard let report = finalReport() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DeviceReportOutput.json(report, forPublic: true), forType: .string)
        copied = true
    }

    func openGitHubIssue() {
        guard let report = finalReport() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DeviceReportOutput.issueClipboard(report), forType: .string)
        issueOpened = true
        NSWorkspace.shared.open(DeviceReportOutput.githubIssue(report))
    }

    // MARK: - Ending

    /// Gives the mouse back to the app. Safe to call more than once. Every step has already
    /// put back what it changed, so this only resumes the app's own reads.
    func endSession() {
        capture?.stop()
        capture = nil
        listening = false
        if sessionOpen {
            controller.endDeviceTest()
            sessionOpen = false
        }
    }

    /// Back to the start, for the next time the window opens.
    func reset() {
        endSession()
        stage = .intro
        report = nil
        blocker = nil
        needsRelaunch = false
        connection = nil
        maxProbe = false
        dimmed = nil
        turnedRed = nil
        buttonsSeen = []
        comment = ""
        credit = ""
        replyEmail = ""
        copied = false
        issueOpened = false
    }
}

extension DeviceTestModel {
    /// Sample state for the `render-device-test` command: one screen of a plausible run, no
    /// device needed. The values are illustrative, not from any real mouse.
    func loadPreview(_ stage: Stage, known: Bool, ranSteps: Bool) {
        previewKnown = known
        func attempts(_ answered: [UInt8]) -> [DeviceReport.TransactionResult] {
            DeviceProbe.knownTransactionIds.map { .init(id: $0, answered: answered.contains($0),
                                                        groups: nil, error: answered.contains($0) ? nil : "timed out") }
        }
        var report = Self.emptyReport(
            pid: 0x00DB, name: "Razer Cobra HyperSpeed",
            interfaces: Array(repeating: DeviceProbe.Interface(productID: 0x00DB, product: "Razer Cobra HyperSpeed",
                                                               usagePage: 1, usage: 2, maxFeatureReportSize: 90,
                                                               maxInputReportSize: 8, transport: "USB"), count: 5),
            control: 2,
            identify: .init(outcome: .passed, data: .init(firmware: "v1.0", standardAttempts: attempts([0x1F, 0x3F, 0x08]),
                                                          lightingAttempts: attempts([0x1F, 0x3F, 0x08]),
                                                          standardId: 0x1F, lightingId: 0x1F)))
        report.battery = .init(outcome: .passed, data: .init(raw: 163, percent: 64, charging: false))
        if ranSteps {
            report.dpi = .init(outcome: .passed, data: .init(original: 1600, test: 1550, readBack: 1550, restored: true,
                                                            stages: [400, 800, 1600, 3200, 6400], maxProbe: nil))
            report.polling = .init(outcome: .passed, data: .init(original: 1000, test: 500, readBack: 500, restored: true))
            report.lighting = .init(outcome: .passed, data: .init(groups: ["LOGO": 8], dimShown: true, redShown: true,
                                                                 dimmed: true, turnedRed: true, restored: true))
            dimmed = .yes
            turnedRed = .yes
        }
        buttonsSeen = ["09:04", "09:05", "07:1e", "07:1f", "07:20"]
        report.buttons = .init(outcome: .passed, data: .init(seen: buttonsSeen))
        listening = true
        connection = .dongle
        self.report = report
        self.report?.device.connection = .dongle
        self.stage = stage
    }
}

extension DeviceReport {
    /// "26.6.2": the OS version and nothing else about the Mac.
    static var currentMacOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// Which screen follows which. Pure, so the order is tested apart from the window: the model
/// only adds what happens on arriving (Battery reads itself, the button step listens).
enum DeviceTestFlow {
    static func next(from stage: DeviceTestModel.Stage) -> DeviceTestModel.Stage? {
        switch stage {
        case .identify: return .battery
        case .battery: return .dpi
        case .dpi: return .polling
        case .polling: return .lighting
        case .lighting: return .buttons
        case .buttons: return .review
        case .intro, .permission, .review: return nil
        }
    }

    /// `identifyRan` is false when the test went straight to Review without Input Monitoring:
    /// there are no steps behind it to go back to.
    static func back(from stage: DeviceTestModel.Stage, identifyRan: Bool) -> DeviceTestModel.Stage? {
        switch stage {
        case .battery: return .identify
        case .dpi: return .battery
        case .polling: return .dpi
        case .lighting: return .polling
        case .buttons: return .lighting
        case .review: return identifyRan ? .buttons : nil
        case .intro, .permission, .identify: return nil
        }
    }
}

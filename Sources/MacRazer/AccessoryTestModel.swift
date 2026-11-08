// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit

/// Drives the lighting test for a keyboard or mousepad (`AccessoryTestView`): the mouse
/// test's Identify and Lighting steps, run on the accessory through its own controller, and
/// the same report, review and Send. Nothing else a mouse test asks applies to an accessory.
@MainActor
final class AccessoryTestModel: ObservableObject {
    enum Stage: Equatable { case intro, lighting, review }

    @Published private(set) var stage = Stage.intro
    @Published private(set) var running = false {
        didSet {
            guard !running else { return }
            let waiting = idleWaiters
            idleWaiters = []
            waiting.forEach { $0() }
        }
    }
    private var idleWaiters: [() -> Void] = []
    @Published private(set) var report: DeviceReport?
    @Published var dimmed: DeviceTestModel.Answer? { didSet { foldAnswers() } }
    @Published var turnedRed: DeviceTestModel.Answer? { didSet { foldAnswers() } }
    @Published var comment = ""
    @Published var credit = ""
    @Published var replyEmail = ""
    @Published private(set) var copied = false
    @Published private(set) var issueOpened = false
    @Published private(set) var sendState = DeviceTestModel.SendState.idle
    /// Bumped by `reset`, so a Send still in flight when the window closes can't land on the
    /// next test.
    private var generation = 0

    /// The accessory under test. Set by `load` before the window shows.
    @Published private(set) var accessory: AccessoryController?
    /// Where Send goes, or nil in a build without the Worker, which hides Send.
    let reportEndpoint: URL?

    init(reportEndpoint: URL? = WorkerEndpoint.deviceReports) {
        self.reportEndpoint = reportEndpoint
    }

    var canSend: Bool { reportEndpoint != nil }

    /// Runs `body` once the test isn't running: Quit waits on this, because the lights may be
    /// dark or red until it ends.
    func whenIdle(_ body: @escaping () -> Void) {
        if running { idleWaiters.append(body) } else { body() }
    }

    /// Points the window at `accessory`. A different one starts over; the same one keeps
    /// whatever screen it was on.
    func load(_ accessory: AccessoryController) {
        guard accessory.id != self.accessory?.id else { return }
        reset()
        self.accessory = accessory
    }

    /// "keyboard" or "mousepad", for the window's sentences.
    var noun: String { (accessory?.info.kind ?? .keyboard).label.lowercased() }
    var deviceName: String { accessory?.info.name ?? "Razer \(noun)" }

    /// Whether the test can also turn the lights red: only when there's an effect to put
    /// back afterwards (`AccessoryController.lightingRestoreReport`).
    var canShowRed: Bool { accessory?.lightingRestoreReport() != nil }

    // MARK: Running

    func start() {
        guard let accessory, !running else { return }
        stage = .lighting
        dimmed = nil
        turnedRed = nil
        Task { await run(accessory) }
    }

    private struct Result: Sendable {
        let name: String
        let identify: DeviceReport.StepRecord<DeviceReport.IdentifyData>
        let lighting: DeviceReport.StepRecord<DeviceReport.LightingData>
        let interfaces: [DeviceProbe.Interface]
        let control: Int?
    }

    private func run(_ accessory: AccessoryController) async {
        running = true
        defer { running = false }
        let info = accessory.info
        let restore = accessory.lightingRestoreReport()
        let started = generation
        let result = await accessory.runTest { device -> Result in
            let (identify, lighting) = DeviceTestSteps.accessoryLighting(device, info: info, restoreEffect: restore, seconds: 3)
            let (interfaces, control) = HIDDevice.interfaceSummaries(vendorId: Razer.vendorId, opened: device)
            return Result(name: device.productName, identify: identify, lighting: lighting,
                          interfaces: interfaces, control: control)
        }
        // Closed and reset while it ran: the result is for a window that has moved on.
        guard generation == started else { return }
        guard let result else {
            report = DeviceTestSteps.accessoryReport(
                info: info, name: info.name, interfaces: [], control: nil,
                identify: .init(outcome: .failed, error: "The \(noun) wasn't reachable."),
                lighting: .init(outcome: .skipped, error: "The \(noun) wasn't reachable."))
            return
        }
        report = DeviceTestSteps.accessoryReport(info: info, name: result.name.isEmpty ? info.name : result.name,
                                                 interfaces: result.interfaces, control: result.control,
                                                 identify: result.identify, lighting: result.lighting)
    }

    private func foldAnswers() {
        guard var record = report?.lighting else { return }
        DeviceTestSteps.answered(dimmed: dimmed?.asBool, turnedRed: turnedRed?.asBool, &record)
        report?.lighting = record
    }

    /// Every check that ran has an answer, "not sure" included, so Next can move on.
    var answered: Bool {
        guard let data = report?.lighting.data, data.dimShown else { return report != nil }
        return dimmed != nil && (!data.redShown || turnedRed != nil)
    }

    func next() {
        guard !running, stage == .lighting, report != nil, answered else { return }
        stage = .review
    }

    func back() {
        guard !running, stage == .review, sendState != .sent else { return }
        stage = .lighting
    }

    // MARK: Review

    /// The report as it would leave the window now: answers folded in, fields cleaned, and
    /// the verdict worked out.
    func finalReport() -> DeviceReport? {
        guard var report else { return nil }
        report.comment = DeviceReportOutput.cleaned(comment, max: DeviceReportOutput.maxComment,
                                                    units: DeviceReportOutput.maxCommentUnits, singleLine: false)
        report.credit = DeviceReportOutput.cleaned(credit, max: DeviceReportOutput.maxCredit,
                                                   units: DeviceReportOutput.maxCreditUnits, singleLine: true)
        report.replyEmail = emailProblem == nil
            ? DeviceReportOutput.cleaned(replyEmail, max: DeviceReportOutput.maxEmail,
                                         units: DeviceReportOutput.maxEmail, singleLine: true) : nil
        report.verdict = report.currentVerdict()
        return DeviceReportOutput.fitted(report)
    }

    var emailProblem: String? { DeviceReportOutput.emailProblem(replyEmail) }

    /// Without the reply email: a clipboard tends to end up pasted somewhere public.
    func copyReport() {
        guard let report = finalReport() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DeviceReportOutput.json(report, forPublic: true), forType: .string)
        copied = true
    }

    func send() {
        guard let endpoint = reportEndpoint, sendState != .sending, sendState != .sent, emailProblem == nil,
              let report = finalReport() else { return }
        sendState = .sending
        let started = generation
        Task {
            let outcome = await DeviceReportSender.send(report, to: endpoint)
            guard generation == started else { return }
            sendState = outcome == .sent ? .sent : .failed(outcome)
        }
    }

    func openGitHubIssue() {
        guard let report = finalReport() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DeviceReportOutput.issueClipboard(report), forType: .string)
        issueOpened = true
        NSWorkspace.shared.open(DeviceReportOutput.githubIssue(report))
    }

    /// What the thank-you says, from the verdict. A model already tested is told it still
    /// works; an untested one, what happens next.
    nonisolated static func thankYou(_ verdict: DeviceTestVerdict, noun: String) -> String {
        switch verdict.kind {
        case .confirmed:
            return "Its lighting works as expected, and your report confirms it. It helps keep the supported list accurate."
        case .possibleRegression:
            return "This \(noun) should work, but its lighting didn't. Your report shows us what to fix."
        case .newAllPassed:
            return "Its lighting worked. Once we've looked at your report, the UNTESTED tag comes off this \(noun)."
        case .newPartlyPassed:
            return "Its lighting didn't work, so your report shows us exactly what to fix for your \(noun)."
        case .partlyTested:
            return "Some answers were \"Not sure\", so this is a partial report. It still helps."
        }
    }

    /// Back to the start, for the next time the window opens.
    func reset() {
        stage = .intro
        report = nil
        dimmed = nil
        turnedRed = nil
        comment = ""
        credit = ""
        replyEmail = ""
        copied = false
        issueOpened = false
        sendState = .idle
        generation += 1
    }
}

extension AccessoryTestModel {
    /// Sample state for `render-accessory-test`: one screen of a plausible run, no device
    /// needed. The values are illustrative, not from any real keyboard.
    func loadPreview(_ stage: Stage, accessory: AccessoryController, sent: Bool) {
        self.accessory = accessory
        let info = accessory.info
        if stage != .intro {
            let ids = DeviceProbe.knownTransactionIds.map {
                DeviceReport.TransactionResult(id: $0, answered: $0 == info.transactionId,
                                               groups: $0 == info.transactionId ? ["BACKLIGHT"] : nil)
            }
            report = DeviceTestSteps.accessoryReport(
                info: info, name: info.name,
                interfaces: [.init(productID: info.pid, product: info.name, usagePage: 1, usage: 2,
                                   maxFeatureReportSize: 90, maxInputReportSize: 8, transport: "USB")],
                control: 0,
                identify: .init(outcome: .passed, data: .init(firmware: "v1.2", standardAttempts: ids, lightingAttempts: ids,
                                                              standardId: info.transactionId, lightingId: info.transactionId)),
                lighting: .init(outcome: .skipped, data: .init(groups: ["BACKLIGHT": 255], dimShown: true, redShown: true,
                                                               restored: true)))
            if stage == .review { dimmed = .yes; turnedRed = .yes }
        }
        if sent { sendState = .sent }
        self.stage = stage
    }
}

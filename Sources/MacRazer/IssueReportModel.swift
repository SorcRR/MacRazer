// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Foundation

/// The "Report an Issue…" window's state: what the person writes, and sending it.
@MainActor
final class IssueReportModel: ObservableObject {
    enum SendState: Equatable {
        case idle
        case sending
        case sent
        case failed(DeviceReportSender.Outcome)
    }

    @Published var description = ""
    @Published var name = ""
    @Published var replyEmail = ""
    @Published var includeDetails = true
    @Published private(set) var sendState = SendState.idle
    /// Open GitHub issue put the description on the clipboard, because it was too long for
    /// the link.
    @Published private(set) var issueNeedsPaste = false

    /// Nil in a build without the Worker: then Open GitHub issue is the only way out.
    let endpoint: URL?
    /// The app and mice right now, asked when the window shows them and when Send is pressed.
    private let currentDetails: () -> IssueReport.Details
    private let transport: DeviceReportSender.Transport

    init(endpoint: URL? = WorkerEndpoint.issueReports,
         details: @escaping () -> IssueReport.Details,
         transport: @escaping DeviceReportSender.Transport = { try await WorkerSession.shared.data(for: $0) }) {
        self.endpoint = endpoint
        self.currentDetails = details
        self.transport = transport
    }

    var canSend: Bool { endpoint != nil }
    var emailProblem: String? { DeviceReportOutput.emailProblem(replyEmail) }
    var hasDescription: Bool { !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var sendDisabled: Bool {
        !hasDescription || emailProblem != nil || sendState == .sending || sendState == .sent
    }
    var details: IssueReport.Details { currentDetails() }

    /// The report as it would go now: cleaned the way the device test cleans its fields, and
    /// cut to fit.
    func finalReport() -> IssueReport {
        let description = DeviceReportOutput.cleaned(self.description, max: DeviceReportOutput.maxComment,
                                                     units: DeviceReportOutput.maxCommentUnits, singleLine: false) ?? ""
        let name = DeviceReportOutput.cleaned(self.name, max: IssueReportOutput.maxName,
                                              units: IssueReportOutput.maxName, singleLine: true)
        let email = emailProblem == nil
            ? DeviceReportOutput.cleaned(replyEmail, max: DeviceReportOutput.maxEmail,
                                         units: DeviceReportOutput.maxEmail, singleLine: true) : nil
        return IssueReportOutput.fitted(IssueReport(description: description, name: name, replyEmail: email,
                                                    details: includeDetails ? currentDetails() : nil))
    }

    func send() async {
        guard let endpoint, !sendDisabled else { return }
        sendState = .sending
        let outcome = await IssueReportSender.send(finalReport(), to: endpoint, transport: transport)
        sendState = outcome == .sent ? .sent : .failed(outcome)
    }

    func openGitHubIssue() {
        let report = finalReport()
        let (url, needsPaste) = IssueReportOutput.githubIssue(report)
        issueNeedsPaste = needsPaste
        if needsPaste {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report.description, forType: .string)
        }
        NSWorkspace.shared.open(url)
    }

    /// Closing after a send starts the next report empty. Closing before keeps the draft,
    /// so a window shut by mistake loses nothing.
    func windowClosed() {
        guard sendState == .sent else { return }
        description = ""
        name = ""
        replyEmail = ""
        includeDetails = true
        sendState = .idle
        issueNeedsPaste = false
    }

    // MARK: Preview

    static func preview() -> IssueReportModel {
        IssueReportModel(endpoint: URL(string: "https://example.com/v1/issue-report"), details: {
            IssueReport.Details(appVersion: "0.8.0", macOS: "26.1", mice: [
                .init(name: "Razer Basilisk V3 Pro", productID: 0x00AB, link: "dongle", supported: true),
            ])
        })
    }

    /// For `render-issue-report sent`.
    func loadPreviewSent(replyEmail: String) {
        self.replyEmail = replyEmail
        sendState = .sent
    }

    /// For `render-issue-report failed`.
    func loadPreviewFailed() { sendState = .failed(.unavailable) }
}

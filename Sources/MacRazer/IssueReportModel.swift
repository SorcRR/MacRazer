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

    @Published var description = "" {
        // The clipboard holds the description as it was; once it changes, the note is wrong.
        didSet { if description != oldValue { issueNeedsPaste = false } }
    }
    @Published var name = ""
    @Published var replyEmail = ""
    @Published var includeDetails = true
    @Published private(set) var sendState = SendState.idle
    /// Open GitHub issue put the description on the clipboard, because it was too long for
    /// the link.
    @Published private(set) var issueNeedsPaste = false
    /// The reply address the sent report carried, for the thank-you screen.
    @Published private(set) var sentReplyEmail: String?

    /// Nil in a build without the Worker: then Open GitHub issue is the only way out.
    let endpoint: URL?
    /// The app and mice right now. Read when the window opens, into `details`.
    private let currentDetails: () -> IssueReport.Details
    /// What the window shows under the checkbox, and so exactly what Send carries: taken
    /// when the window opens, not again at Send, so a mouse plugged in meanwhile can't
    /// slip into a report the person didn't see.
    @Published private(set) var details: IssueReport.Details
    private let transport: DeviceReportSender.Transport

    init(endpoint: URL? = WorkerEndpoint.issueReports,
         details: @escaping () -> IssueReport.Details,
         transport: @escaping DeviceReportSender.Transport = { try await WorkerSession.shared.data(for: $0) }) {
        self.endpoint = endpoint
        self.currentDetails = details
        self.details = details()
        self.transport = transport
    }

    var canSend: Bool { endpoint != nil }
    var emailProblem: String? { DeviceReportOutput.emailProblem(replyEmail) }
    /// Whether there's a description once it's cleaned the way Send cleans it, and blank the
    /// way the Worker's `trim()` sees it, which also drops U+FEFF. Text that's all control
    /// characters is no description: cleaning leaves nothing of it.
    var hasDescription: Bool {
        !cleanedDescription.trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{FEFF}"])).isEmpty
    }
    private var cleanedDescription: String {
        DeviceReportOutput.cleaned(description, max: DeviceReportOutput.maxComment,
                                   units: DeviceReportOutput.maxCommentUnits, singleLine: false) ?? ""
    }
    var sendDisabled: Bool {
        !hasDescription || emailProblem != nil || sendState == .sending || sendState == .sent
    }

    /// The report as it would go now: cleaned the way the device test cleans its fields, and
    /// cut to fit.
    func finalReport() -> IssueReport {
        let description = cleanedDescription
        let name = DeviceReportOutput.cleaned(self.name, max: IssueReportOutput.maxName,
                                              units: IssueReportOutput.maxName, singleLine: true)
        let email = emailProblem == nil
            ? DeviceReportOutput.cleaned(replyEmail, max: DeviceReportOutput.maxEmail,
                                         units: DeviceReportOutput.maxEmail, singleLine: true) : nil
        return IssueReportOutput.fitted(IssueReport(description: description, name: name, replyEmail: email,
                                                    details: includeDetails ? details : nil))
    }

    func send() async {
        guard let endpoint, !sendDisabled else { return }
        sendState = .sending
        let report = finalReport()
        let outcome = await IssueReportSender.send(report, to: endpoint, transport: transport)
        if outcome == .sent { sentReplyEmail = report.replyEmail }
        sendState = outcome == .sent ? .sent : .failed(outcome)
    }

    /// An email with the report in it, for when Send fails. No name or address: the email
    /// itself carries both.
    var mailInstead: URL {
        let report = finalReport()
        let details = report.details.map { "\n\n" + IssueReportOutput.detailLines($0).joined(separator: "\n") } ?? ""
        return ProjectLinks.mail(subject: "MacRazer issue: " + IssueReportOutput.title(report.description),
                                 body: report.description + details)
    }

    func openGitHubIssue() {
        let report = finalReport()
        let (url, needsPaste) = IssueReportOutput.githubIssue(report)
        issueNeedsPaste = needsPaste
        if needsPaste { copyToClipboard(report.description) }
        openURL(url)
    }
    /// Replaced in tests, which mustn't open a browser or touch the clipboard.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var copyToClipboard: (String) -> Void = {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString($0, forType: .string)
    }

    /// Called as the window opens. A report already sent starts the next one empty; one not
    /// sent keeps its draft, so a window shut by mistake loses nothing. Here rather than on
    /// close, because a send still going when the window closes finishes as sent afterwards.
    func windowWillShow() {
        details = currentDetails()
        guard sendState == .sent else { return }
        description = ""
        name = ""
        replyEmail = ""
        includeDetails = true
        sendState = .idle
        sentReplyEmail = nil
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
        sentReplyEmail = replyEmail
        sendState = .sent
    }

    /// For `render-issue-report failed [cap]`.
    func loadPreviewFailed(_ outcome: DeviceReportSender.Outcome = .unavailable) { sendState = .failed(outcome) }
}

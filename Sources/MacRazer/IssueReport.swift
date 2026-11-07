// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// What "Report an Issue…" sends: what the person wrote, who they are if they say, and, if
/// they leave the box ticked, which app, macOS and mice it's about. The Worker checks it
/// field by field against `src/issue.ts` in SorcRR/macrazer-worker and emails it to the
/// maintainer, the same way as a device report.
struct IssueReport: Codable, Equatable {
    /// `ISSUE_SCHEMA` in the Worker. A field added here is refused there until it knows it.
    static let schemaVersion = 1

    var schema = schemaVersion
    var description: String
    var name: String?
    var replyEmail: String?
    var details: Details?

    struct Details: Codable, Equatable {
        var appVersion: String
        var macOS: String
        var mice: [Mouse]
    }

    struct Mouse: Codable, Equatable {
        var name: String
        var productID: Int
        /// "wired", "dongle", "bluetooth" or "unknown", as the usage stats say it.
        var link: String
        /// Whether MacRazer has a verified profile for it.
        var supported: Bool
    }
}

enum IssueReportOutput {
    /// How much of the description's first line titles the email and the GitHub issue.
    /// `SUBJECT_CHARS` in the Worker.
    static let titleCharacters = 80
    /// The Worker's limit for a name, the same as a device report's credit.
    static let maxName = 256

    static func json(_ report: IssueReport, pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return (try? encoder.encode(report)) ?? Data()
    }

    /// The report cut to fit the Worker's 16 KB, so Send never fails on size. Only a
    /// description of 2000 characters that are each several bytes gets near it.
    static func fitted(_ report: IssueReport, maxBytes: Int = DeviceReportOutput.maxReportBytes) -> IssueReport {
        let excess = json(report).count - maxBytes
        guard excess > 0 else { return report }
        var r = report
        r.description = ReportComment.trimmed(report.description, dropping: excess) ?? ""
        return r
    }

    /// The description's first non-blank line, cut to `titleCharacters`, for a GitHub issue's
    /// title. The Worker's email subject starts from the same line but counts code points, not
    /// characters, so for emoji or combined accents the two can cut at different places.
    static func title(_ description: String) -> String {
        let first = description.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard first.count > titleCharacters else { return first }
        return String(first.prefix(titleCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The details as lines of plain text, for the window and the GitHub issue.
    static func detailLines(_ details: IssueReport.Details) -> [String] {
        var lines = ["MacRazer \(details.appVersion) on macOS \(details.macOS)"]
        if details.mice.isEmpty { lines.append("No Razer mouse connected") }
        for mouse in details.mice {
            let link: String
            switch mouse.link {
            case "wired": link = ", wired"
            case "dongle": link = ", over its dongle"
            case "bluetooth": link = ", over Bluetooth"
            default: link = ""
            }
            lines.append(mouse.name + String(format: " (0x%04X)", mouse.productID) + link)
        }
        return lines
    }

    /// The new-issue link for someone who'd rather post in public, and whether the
    /// description was too long for it and has to be pasted in. Never the name or the email:
    /// those were offered for the maintainer alone.
    static func githubIssue(_ report: IssueReport) -> (url: URL, needsPaste: Bool) {
        let footer = "\n\n_Sent from MacRazer's Report an Issue window._"
        let details = report.details.map { "\n\n" + detailLines($0).joined(separator: "\n") } ?? ""
        let title = title(report.description)
        if let url = DeviceReportOutput.issueURL(title: title, body: report.description + details + footer),
           url.absoluteString.count <= DeviceReportOutput.maxIssueURLLength {
            return (url, false)
        }
        // Too long for a link: the title starts it, and the person pastes the rest.
        return (DeviceReportOutput.issueURL(
            title: title, body: "The full description is on your clipboard. Paste it here, please." + details + footer)!, true)
    }
}

/// Posts an issue report to the Worker. The statuses mean what they do for a device report.
enum IssueReportSender {
    static func request(_ report: IssueReport, to endpoint: URL) -> URLRequest {
        DeviceReportSender.request(body: IssueReportOutput.json(IssueReportOutput.fitted(report)), to: endpoint)
    }

    static func send(_ report: IssueReport, to endpoint: URL,
                     transport: @escaping DeviceReportSender.Transport = { try await WorkerSession.shared.data(for: $0) })
        async -> DeviceReportSender.Outcome {
        await DeviceReportSender.post(request(report, to: endpoint), transport: transport)
    }
}

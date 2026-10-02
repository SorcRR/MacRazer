// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The ways a device report leaves the test window, and the checks on what the person typed.
/// Pure, so the rules (what goes where, what's refused) are tested without a window.
enum DeviceReportOutput {
    /// Limits on the free-text fields, the same ones the Worker will enforce on Send.
    static let maxComment = 2000
    static let maxCredit = 64
    static let maxEmail = 254

    /// The report as JSON. `forPublic` drops the reply email: a GitHub issue is public, and
    /// the address is only ever meant for the maintainer.
    static func json(_ report: DeviceReport, forPublic: Bool, pretty: Bool = true) -> String {
        var copy = report
        if forPublic { copy.replyEmail = nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return String(decoding: (try? encoder.encode(copy)) ?? Data(), as: UTF8.self)
    }

    static func issueTitle(_ report: DeviceReport) -> String {
        let prefix = report.verdict?.subjectPrefix ?? "Device report"
        return "\(prefix): \(report.device.name) (\(String(format: "0x%04X", report.device.productID)))"
    }

    /// A short readable summary for the top of an issue, above the full JSON.
    static func summary(_ report: DeviceReport) -> String {
        var lines = ["**\(report.device.name)**, product ID \(String(format: "0x%04X", report.device.productID))"
                     + (report.identify.data?.firmware.map { ", firmware \($0)" } ?? "")
                     + (report.device.connection.map { ", over the \($0.rawValue)" } ?? "")]
        if let verdict = report.verdict {
            if !verdict.passed.isEmpty { lines.append("Passed: " + verdict.passed.joined(separator: ", ")) }
            if !verdict.failed.isEmpty { lines.append("Failed: " + verdict.failed.joined(separator: ", ")) }
            if !verdict.notSupported.isEmpty { lines.append("Not on this mouse: " + verdict.notSupported.joined(separator: ", ")) }
            if !verdict.skipped.isEmpty { lines.append("Skipped: " + verdict.skipped.joined(separator: ", ")) }
        }
        if let comment = report.comment, !comment.isEmpty { lines.append("\n> " + comment.replacingOccurrences(of: "\n", with: "\n> ")) }
        if let credit = report.credit, !credit.isEmpty { lines.append("Credit: \(credit)") }
        return lines.joined(separator: "\n")
    }

    /// Past this, an issue link is too long to rely on, and the report goes on the clipboard
    /// instead, with the issue body asking for it to be pasted.
    static let maxIssueURLLength = 7000

    struct Issue: Equatable {
        let url: URL
        /// The full JSON didn't fit: put it on the clipboard before opening `url`.
        let needsClipboard: Bool
    }

    static func githubIssue(_ report: DeviceReport) -> Issue {
        let json = json(report, forPublic: true, pretty: true)
        let footer = "\n\n_Sent from MacRazer's device test._"
        let full = summary(report) + "\n\n<details><summary>Full report</summary>\n\n```json\n" + json + "\n```\n</details>" + footer
        if let url = issueURL(title: issueTitle(report), body: full), url.absoluteString.count <= maxIssueURLLength {
            return Issue(url: url, needsClipboard: false)
        }
        let short = summary(report) + "\n\nThe full report is on your clipboard. Paste it below this line, please.\n\n" + footer
        // The short body has no JSON in it, so it always fits.
        return Issue(url: issueURL(title: issueTitle(report), body: short)!, needsClipboard: true)
    }

    private static func issueURL(title: String, body: String) -> URL? {
        var components = URLComponents(url: ProjectLinks.issues.appendingPathComponent("new"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        return components?.url
    }

    /// Why an email address can't be used, or nil if it's fine (or empty: it's optional).
    /// Deliberately loose: one @, something either side, a dot in the domain. Line breaks are
    /// refused outright, because this ends up as an email header on Send.
    static func emailProblem(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.contains(where: { $0.isNewline }) || trimmed.count > maxEmail { return "That doesn't look like an email address." }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."), !trimmed.contains(" ")
        else { return "That doesn't look like an email address." }
        return nil
    }

    /// The free-text fields as they go into a report: trimmed, capped, empty as nil.
    static func cleaned(_ text: String, max: Int, singleLine: Bool) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine { value = value.components(separatedBy: .newlines).joined(separator: " ") }
        if value.count > max { value = String(value.prefix(max)) }
        return value.isEmpty ? nil : value
    }
}

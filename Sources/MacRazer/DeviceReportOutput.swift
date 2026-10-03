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

    /// The most a report may be, as compact JSON: the Worker refuses anything bigger.
    static let maxReportBytes = 16 * 1024

    static func size(_ report: DeviceReport) -> Int { json(report, forPublic: false, pretty: false).utf8.count }

    /// The report cut to fit `maxReportBytes`, so Send never fails on size. A normal run is a
    /// few KB and comes back untouched. A long one sheds per-command evidence first, a step at
    /// a time, Identify's last since it shows which ids answered; then, only if that isn't
    /// enough, the end of the comment, which can be 2000 emoji of many bytes each.
    static func fitted(_ report: DeviceReport, maxBytes: Int = maxReportBytes) -> DeviceReport {
        var r = report
        let evidence: [(String, WritableKeyPath<DeviceReport, [RecordingChannel.Exchange]>)] = [
            ("lighting", \.lighting.exchanges), ("polling", \.polling.exchanges), ("dpi", \.dpi.exchanges),
            ("battery", \.battery.exchanges), ("buttons", \.buttons.exchanges), ("identify", \.identify.exchanges),
        ]
        for (name, path) in evidence where size(r) > maxBytes && !r[keyPath: path].isEmpty {
            r[keyPath: path] = []
            r.exchangesDropped = (r.exchangesDropped ?? []) + [name]
        }
        // Every scalar is at least a byte, so dropping as many scalars as there are bytes
        // over always gets under, in one pass. The loop is only a guard.
        while case let excess = size(r) - maxBytes, excess > 0, let comment = r.comment, !comment.isEmpty {
            let kept = String(comment.unicodeScalars.dropLast(excess))
            r.comment = kept.isEmpty ? nil : kept
        }
        return r
    }

    static func issueTitle(_ report: DeviceReport) -> String {
        let prefix = report.verdict?.subjectPrefix ?? "Device report"
        return "\(prefix): \(report.device.name) (\(String(format: "0x%04X", report.device.productID)))"
    }

    /// A short readable summary for the top of an issue, above the full JSON. `withComment`
    /// false leaves the comment out, for a link that would be too long with it.
    static func summary(_ report: DeviceReport, withComment: Bool = true) -> String {
        var lines = ["**\(report.device.name)**, product ID \(String(format: "0x%04X", report.device.productID))"
                     + (report.identify.data?.firmware.map { ", firmware \($0)" } ?? "")
                     + (report.device.connection.map { ", over the \($0.rawValue)" } ?? "")]
        if let verdict = report.verdict {
            if !verdict.passed.isEmpty { lines.append("Passed: " + verdict.passed.joined(separator: ", ")) }
            if !verdict.failed.isEmpty { lines.append("Failed: " + verdict.failed.joined(separator: ", ")) }
            if !verdict.notSupported.isEmpty { lines.append("Not on this mouse: " + verdict.notSupported.joined(separator: ", ")) }
            if !verdict.skipped.isEmpty { lines.append("Skipped: " + verdict.skipped.joined(separator: ", ")) }
        }
        if withComment, let comment = report.comment, !comment.isEmpty {
            lines.append("\n> " + comment.replacingOccurrences(of: "\n", with: "\n> "))
        }
        if let credit = report.credit, !credit.isEmpty { lines.append("Credit: \(credit)") }
        return lines.joined(separator: "\n")
    }

    /// Past this, an issue link is too long to rely on: GitHub and browsers cut long ones off.
    static let maxIssueURLLength = 7000

    /// The new-issue link: the summary, and a request to paste the full report, which goes on
    /// the clipboard (`issueClipboard`). Never the JSON itself: a full report, escaped into a
    /// link, often runs past what GitHub accepts, and a cut-off report is worse than none.
    static func githubIssue(_ report: DeviceReport) -> URL {
        let ask = "\n\nThe full report is on your clipboard. Paste it below this line, please.\n\n"
        let footer = "_Sent from MacRazer's device test._"
        if let url = issueURL(title: issueTitle(report), body: summary(report) + ask + footer),
           url.absoluteString.count <= maxIssueURLLength {
            return url
        }
        // Only a long comment gets it this far, and the comment is in the report anyway.
        return issueURL(title: issueTitle(report), body: summary(report, withComment: false) + ask + footer)!
    }

    /// What Open GitHub issue puts on the clipboard: the public report in a collapsed JSON
    /// block, so pasting it into the issue reads well.
    static func issueClipboard(_ report: DeviceReport) -> String {
        "<details><summary>Full report</summary>\n\n```json\n" + json(report, forPublic: true) + "\n```\n</details>"
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

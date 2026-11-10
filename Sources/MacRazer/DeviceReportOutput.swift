// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The ways a device report leaves the test window, and the checks on what the person typed.
/// Pure, so the rules (what goes where, what's refused) are tested without a window.
enum DeviceReportOutput {
    /// Limits on the free-text fields. Characters are what the person sees and the counter
    /// shows. UTF-16 code units are what the Worker counts (a JavaScript string's length),
    /// and one character can be many of them, so `cleaned` keeps each field within both and
    /// a real report is never refused for its length.
    static let maxComment = 2000
    static let maxCommentUnits = 8000
    static let maxCredit = 64
    static let maxCreditUnits = 256
    static let maxEmail = 254

    /// The report as JSON. `forPublic` gives `publicCopy`: a GitHub issue is public.
    static func json(_ report: DeviceReport, forPublic: Bool, pretty: Bool = true) -> String {
        let copy = forPublic ? publicCopy(report) : report
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return String(decoding: (try? encoder.encode(copy)) ?? Data(), as: UTF8.self)
    }

    /// The report as a GitHub issue may show it. No reply email: that is only for the
    /// maintainer. Of the apps running on the person's Mac, only Razer's are named. Any other
    /// app that watches mouse buttons, or sent a recorded key, becomes a count or "another app".
    /// The report Send emails keeps every name.
    static func publicCopy(_ report: DeviceReport) -> DeviceReport {
        var copy = report
        copy.replyEmail = nil
        // Razer's by the scan, or by its name: a key Synapse posted still says so after the
        // person quit it and Review scanned again.
        let scanned = Set(report.software?.razer ?? [])
        let razer = { (name: String) in scanned.contains(name) || name.lowercased().hasPrefix("razer") }
        if var software = copy.software {
            let others = software.mouseTaps.filter { !razer($0) }.count + (software.otherApps ?? 0)
            software.mouseTaps = software.mouseTaps.filter(razer)
            software.otherApps = others == 0 ? nil : others
            copy.software = software
        }
        if var data = copy.buttons.data, let keys = data.keys {
            var kept: [DeviceReport.KeyPress] = []
            for var key in keys {
                if let app = key.postedBy, !razer(app) { key.postedBy = anotherApp }
                if !kept.contains(key) { kept.append(key) }
            }
            data.keys = kept
            copy.buttons.data = data
        }
        return copy
    }

    static let anotherApp = "another app"

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
        // One trim fits, since it measures the comment as the encoder writes it (see
        // `ReportComment`). The loop is only a guard in case that measurement and the
        // report's encoding ever disagree.
        while case let excess = size(r) - maxBytes, excess > 0, let comment = r.comment, !comment.isEmpty {
            r.comment = ReportComment.trimmed(comment, dropping: excess)
        }
        return r
    }

    /// "mouse", or "keyboard" or "mousepad" for an accessory's lighting test.
    static func noun(_ report: DeviceReport) -> String {
        report.accessory?.kind.label.lowercased() ?? "mouse"
    }

    /// The report as it leaves a test window: `comment` already cleaned by the window (the
    /// mouse test puts the dock line ahead of it), the credit and reply email cleaned here, a
    /// bad email left out, and the verdict worked out. Not yet `fitted`: see `FitCache`.
    static func prepared(_ report: DeviceReport, comment: String?, credit: String, replyEmail: String) -> DeviceReport {
        var report = report
        report.comment = comment
        report.credit = cleaned(credit, max: maxCredit, units: maxCreditUnits, singleLine: true)
        report.replyEmail = emailProblem(replyEmail) == nil
            ? cleaned(replyEmail, max: maxEmail, units: maxEmail, singleLine: true) : nil
        report.verdict = report.currentVerdict()
        return report
    }

    /// `fitted`, remembered for the last report it was asked about. Fitting encodes the
    /// report to measure it, and a review screen asks on every keystroke.
    struct FitCache {
        private var last: (input: DeviceReport, output: DeviceReport)?

        mutating func fitted(_ report: DeviceReport) -> DeviceReport {
            if let last, last.input == report { return last.output }
            let output = DeviceReportOutput.fitted(report)
            last = (report, output)
            return output
        }
    }

    static func issueTitle(_ report: DeviceReport) -> String {
        let prefix = report.verdict?.subjectPrefix(noun: noun(report)) ?? "Device report"
        return "\(prefix): \(report.device.name) (\(String(format: "0x%04X", report.device.productID)))"
    }

    /// A short readable summary for the top of an issue, above the full JSON. `withComment`
    /// false leaves the comment out, for a link that would be too long with it.
    static func summary(_ report: DeviceReport, withComment: Bool = true) -> String {
        let report = publicCopy(report)
        var lines = ["**\(report.device.name)**, product ID \(String(format: "0x%04X", report.device.productID))"
                     + (report.identify.data?.firmware.map { ", firmware \($0)" } ?? "")
                     + (report.device.connection.map { $0 == .bluetooth ? ", over Bluetooth" : ", over the \($0.rawValue)" } ?? "")]
        if let verdict = report.verdict {
            if !verdict.passed.isEmpty { lines.append("Passed: " + verdict.passed.joined(separator: ", ")) }
            if !verdict.failed.isEmpty { lines.append("Failed: " + verdict.failed.joined(separator: ", ")) }
            if !verdict.notSupported.isEmpty {
                lines.append("Not on this \(noun(report)): " + verdict.notSupported.joined(separator: ", "))
            }
            if !verdict.skipped.isEmpty { lines.append("Skipped: " + verdict.skipped.joined(separator: ", ")) }
        }
        if let reads = report.capabilities?.reads {
            var answered: [String] = []
            for read in reads where read.answer == .answered && read.led == nil && !answered.contains(read.name) {
                answered.append(read.name)
            }
            // Unique: over Bluetooth, brightness and the zone effect both name an LED.
            var leds: [String] = []
            for led in reads.filter({ $0.answer == .answered }).compactMap(\.led) {
                let hex = String(format: "0x%02X", led)
                if !leds.contains(hex) { leds.append(hex) }
            }
            if !leds.isEmpty { answered.append("lighting zones " + leds.joined(separator: " ")) }
            if let table = report.capabilities?.buttonTable, !table.isEmpty {
                answered.append("button table (\(table.count) \(table.count == 1 ? "entry" : "entries"))")
            }
            lines.append("Also answers: " + (answered.isEmpty ? "none of the extra reads" : answered.joined(separator: ", ")))
        }
        if let software = report.software, !software.isEmpty {
            var names = software.razer + software.mouseTaps
            if let others = software.otherApps { names.append("\(others) other \(others == 1 ? "app" : "apps")") }
            lines.append("Running, can take the buttons: " + DeviceTestVerdict.names(names))
        }
        if let keys = report.buttons.data?.keys {
            let label = report.buttons.outcome == .passed || keys.isEmpty ? "Keys recorded" : "Keys only, no mouse buttons"
            lines.append(label + ": " + (keys.isEmpty ? "none" : keys.map(\.displayName).joined(separator: ", ")))
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

    static func issueURL(title: String, body: String) -> URL? {
        var components = URLComponents(url: ProjectLinks.issues.appendingPathComponent("new"), resolvingAgainstBaseURL: false)
        components?.setEncodedQuery([URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)])
        return components?.url
    }

    /// Why an email address can't be used, or nil if it's fine (or empty: it's optional).
    /// Deliberately loose: one @, something either side, a dot in the domain. Line breaks are
    /// refused outright, because this ends up as an email header on Send.
    static func emailProblem(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        let problem = "That doesn't look like an email address."
        // No whitespace or control character of any kind: the Worker refuses them, and a
        // line break is how a header gets injected. U+FEFF counts as space to JavaScript.
        if trimmed.utf16.count > maxEmail || trimmed.unicodeScalars.contains(where: {
            $0.properties.isWhitespace || $0.properties.generalCategory == .control || $0 == "\u{FEFF}"
        }) { return problem }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix(".")
        else { return problem }
        return nil
    }

    /// The free-text fields as they go into a report: trimmed, capped at `max` characters and
    /// `units` UTF-16 code units, empty as nil. Control characters go, since the Worker
    /// refuses them. Line breaks become plain "\n", or spaces when `singleLine`.
    static func cleaned(_ text: String, max: Int, units: Int, singleLine: Bool) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            switch scalar {
            case "\n", "\r", "\u{85}", "\u{2028}", "\u{2029}": scalars.append(singleLine ? " " : "\n")
            case "\t": scalars.append(singleLine ? " " : "\t")
            default: if scalar.properties.generalCategory != .control { scalars.append(scalar) }
            }
        }
        var value = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > max { value = String(value.prefix(max)) }
        if value.utf16.count > units {
            var kept = "", used = 0
            for character in value {
                used += character.utf16.count
                if used > units { break }
                kept.append(character)
            }
            value = kept
        }
        return value.isEmpty ? nil : value
    }
}

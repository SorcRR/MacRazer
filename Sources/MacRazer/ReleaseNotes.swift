// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Turns a GitHub release body into something the popover can show in 320 points.
///
/// Pure — no network, no UI — so every shape the notes come in can be replayed in a test,
/// which matters because the input is prose written by hand months apart. The parser is
/// deliberately forgiving: anything it can't classify still reaches the reader as plain text
/// rather than being dropped.
struct ReleaseNotes: Equatable {
    /// One bullet, split so the popover can set the first line apart from the rest.
    struct Item: Equatable {
        /// The gist. Empty when the bullet has no natural lead, in which case `detail` carries
        /// the whole thing rather than the item being silently thinned to nothing.
        let headline: String
        let detail: String
    }

    /// A heading, e.g. "Added" / "Fixed", with the bullets under it. The title is empty for
    /// bullets that appear before any heading.
    struct Section: Equatable {
        let title: String
        let items: [Item]
    }

    /// The prose above the first heading — usually one line saying what the release is about.
    let summary: String
    let sections: [Section]

    var isEmpty: Bool { summary.isEmpty && sections.isEmpty }

    /// Sections that exist for someone reading the release page, not someone already running
    /// the app. Install instructions are the obvious one: by the time these notes are on
    /// screen the reader has plainly managed it.
    private static let droppedSections: Set<String> = ["install", "installation", "download"]

    /// A headline longer than this stops being a headline and is just the sentence again in
    /// bold, so the item is left as one block of detail instead.
    private static let maxHeadline = 90

    static func parse(_ body: String) -> ReleaseNotes {
        var summaryLines: [String] = []
        var sections: [Section] = []
        var currentTitle: String?
        var currentBullets: [String] = []

        func closeSection() {
            defer { currentTitle = nil; currentBullets = [] }
            guard !currentBullets.isEmpty else { return }
            // An untitled section is a body that opens straight into a list, with no headings
            // at all. It still gets shown — the view leaves the title label off.
            let title = currentTitle ?? ""
            guard !droppedSections.contains(title.lowercased()) else { return }
            sections.append(Section(title: title, items: currentBullets.map(item(from:))))
        }

        var previousLineWasBlank = true
        // The summary ends at the first bullet or heading and does not resume: prose further
        // down belongs where it was written, not hoisted above the sections it followed.
        var inSummary = true
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // The changelog link is a footer for the release page; in the app it's a dead end.
            if line.lowercased().hasPrefix("**full changelog:") { break }
            defer { previousLineWasBlank = line.isEmpty }

            if let heading = headingTitle(line) {
                inSummary = false
                closeSection()
                currentTitle = heading
            } else if let bullet = bulletText(line) {
                inSummary = false
                currentBullets.append(bullet)
            } else if inSummary, !line.isEmpty {
                // Blockquote callouts read as emphasis on the page and as clutter here; keep
                // the words, drop the marker.
                let text = strip(line.hasPrefix("> ") ? String(line.dropFirst(2)) : line)
                // Markdown wraps: a paragraph split over several source lines is one
                // paragraph, and joining them with a break instead put a blank line through
                // the middle of the summary sentence. Only a blank line starts a new one.
                if previousLineWasBlank || summaryLines.isEmpty {
                    summaryLines.append(text)
                } else {
                    summaryLines[summaryLines.count - 1] += " " + text
                }
            } else if !line.isEmpty, !previousLineWasBlank, !currentBullets.isEmpty {
                // A wrapped bullet. Markdown joins a line that follows one directly, and a
                // long bullet split over two lines is the one way a hand-written body loses
                // half a sentence here.
                currentBullets[currentBullets.count - 1] += " " + line
            }
            // Anything left is prose under a heading with no bullets — a section like Install
            // written as paragraphs. `closeSection` drops it for being empty.
        }
        closeSection()

        return ReleaseNotes(summary: summaryLines.joined(separator: "\n\n"), sections: sections)
    }

    /// The title of an ATX heading at any level, or nil.
    ///
    /// Any level, because our own notes use `###` while GitHub's "Generate release notes"
    /// button emits `##` — and a body whose headings all went unrecognised would arrive as
    /// one undifferentiated blob of summary.
    private static func headingTitle(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, line.dropFirst(hashes.count).hasPrefix(" ") else { return nil }
        let title = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : strip(title)
    }

    /// The text of a list item, or nil. `*` and `+` are markdown list markers too, and the
    /// generated notes use `*`.
    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    /// Splits a bullet into a lead and the rest.
    ///
    /// Real notes come in at least four shapes: bold lead then detail, a bold run in the
    /// middle, a quoted feature name in bold, and no emphasis at all. A leading bold run is
    /// the clearest signal of intent, so it wins; otherwise the first sentence stands in, and
    /// if even that is too long the item is left whole.
    static func item(from bullet: String) -> Item {
        let text = bullet.trimmingCharacters(in: .whitespaces)

        if text.hasPrefix("**"), let close = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex) {
            let headline = String(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound])
            let rest = String(text[close.upperBound...])
            if headline.count <= maxHeadline {
                return Item(headline: strip(headline), detail: strip(trimLead(rest)))
            }
        }

        if let end = firstSentenceEnd(text) {
            let headline = String(text[..<end])
            if headline.count <= maxHeadline {
                let rest = String(text[end...])
                return Item(headline: strip(headline), detail: strip(trimLead(rest)))
            }
        }
        return Item(headline: "", detail: strip(text))
    }

    /// Index just past the first ". " — not `.` alone, which would cut "0.3.1" and "e.g." in
    /// half, and not "…", which these notes use for menu titles like "Settings…".
    private static func firstSentenceEnd(_ text: String) -> String.Index? {
        guard let r = text.range(of: ". ") else {
            return text.hasSuffix(".") ? text.endIndex : nil
        }
        return r.upperBound
    }

    /// Drops the punctuation and whitespace left dangling when a lead is split off. Dashes
    /// included: `**Name** — what it does` is the shape our own notes use most, and leaving
    /// the dash puts "— what it does" on its own line looking like a mistake.
    private static let leadJunk: Set<Character> = [",", ":", ".", " ", "—", "–", "-"]
    private static func trimLead(_ s: String) -> String {
        var out = s
        while let f = out.first, leadJunk.contains(f) { out.removeFirst() }
        return out
    }

    /// Markdown emphasis, code ticks and links reduced to their text. SwiftUI can render
    /// markdown, but only cleanly for a whole string — these fragments are recombined into
    /// styled runs by the view, so they arrive as plain text.
    static func strip(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        // [text](url) → text. The opening bracket has to be the one that actually starts the
        // link: pairing the *first* `[` with the first later `](` let a stray bracket swallow
        // everything between it and the next real link.
        var searchFrom = out.startIndex
        while let open = out.range(of: "[", range: searchFrom..<out.endIndex) {
            guard let close = out.range(of: "](", range: open.upperBound..<out.endIndex),
                  let end = out.range(of: ")", range: close.upperBound..<out.endIndex) else { break }
            // Another `[` between this one and the `]` means this one isn't the link's opener.
            if out.range(of: "[", range: open.upperBound..<close.lowerBound) != nil {
                searchFrom = open.upperBound
                continue
            }
            let text = String(out[open.upperBound..<close.lowerBound])
            out.replaceSubrange(open.lowerBound..<end.upperBound, with: text)
            // Resume after the text just substituted, so a `[` inside it is not re-examined.
            searchFrom = out.index(open.lowerBound, offsetBy: text.count)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

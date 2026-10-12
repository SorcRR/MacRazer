// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Trims a report's free-text comment so the report fits a byte limit. Shared by device and
/// crash reports, whose JSON the Worker caps at the same size.
enum ReportComment {
    /// `comment` with whole characters removed from the end until its JSON is at least
    /// `excess` bytes smaller, or nil when nothing is left.
    ///
    /// Each character is measured as the report's encoder writes it: an emoji is its UTF-8
    /// bytes, a quote or a slash is two, a control character up to six. Counting raw bytes
    /// instead would cut too much from a comment full of characters JSON escapes, and cutting
    /// a character per byte over would cut far too much from one full of emoji. Whole
    /// characters only, so a family emoji is never left half built.
    static func trimmed(_ comment: String, dropping excess: Int) -> String? {
        guard excess > 0 else { return comment }
        let encoder = JSONEncoder()
        var sizes: [Character: Int] = [:]
        func jsonSize(_ c: Character) -> Int {
            // Almost every character is written as its plain UTF-8 bytes. Only the few JSON may
            // escape (control characters, quote, backslash, slash, the two line separators)
            // go through the encoder, which keeps this cheap: the report windows fit the
            // report on every keystroke.
            guard c.unicodeScalars.contains(where: Self.mayBeEscaped) else { return c.utf8.count }
            if let known = sizes[c] { return known }
            // The encoded fragment is the character in quotes; the quotes aren't its cost.
            let size = (try? encoder.encode(String(c))).map { $0.count - 2 } ?? c.utf8.count
            sizes[c] = size
            return size
        }
        var budget = comment.reduce(0) { $0 + jsonSize($1) } - excess
        let kept = String(comment.prefix {
            budget -= jsonSize($0)
            return budget >= 0
        })
        return kept.isEmpty ? nil : kept
    }

    private static func mayBeEscaped(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x20 || s == "\"" || s == "\\" || s == "/" || s.value == 0x2028 || s.value == 0x2029
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

extension ListFormatter {
    /// `items` joined as an English list ("A and B", "A, B, and C"). The sentences around it
    /// are English whatever the Mac's language, as is the whole interface, so the list's
    /// "and" must be too: the Mac's own locale would make it "A y B" in Spanish.
    static func english(_ items: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = Locale(identifier: "en")
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }
}

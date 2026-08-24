// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Dotted-integer version compare (e.g. "0.1.10" > "0.1.9") — plain semver-ish strings only,
/// no pre-release suffixes to worry about for this project.
enum VersionCompare {
    static func isNewer(_ remote: String, than local: String) -> Bool {
        // Positional, never compacted: dropping an unparseable component shifts the later
        // ones left, so "v0.1.0" parsed as [1, 0] and compared 1 > 0 against "0.2.0",
        // reporting a downgrade as an update. Each component contributes its leading run of
        // digits after any prefix junk ("v1" / "release-1" → 1, "0-beta" → 0), so a tag
        // shape UpdateChecker doesn't strip can't silently reorder releases either.
        let r = remote.split(separator: ".").map(Self.leadingNumber)
        let l = local.split(separator: ".").map(Self.leadingNumber)
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    private static func leadingNumber(_ component: Substring) -> Int {
        Int(component.drop { !$0.isNumber }.prefix { $0.isNumber }) ?? 0
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Dotted-integer version compare (e.g. "0.1.10" > "0.1.9") — plain semver-ish strings only,
/// no pre-release suffixes to worry about for this project.
enum VersionCompare {
    static func isNewer(_ remote: String, than local: String) -> Bool {
        // `Int($0) ?? 0`, not compactMap: dropping an unparseable component would shift the
        // later ones left, so "v0.1.0" parsed as [1, 0] and compared 1 > 0 against "0.2.0"
        // — reporting a downgrade as an update. Unparseable components read as 0 in place.
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let l = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Whether this launch is the first one on a new version, and so worth saying something about.
///
/// The app cannot otherwise tell: it installs updates itself and relaunches, and with
/// "Install updates automatically" on it does that without ever showing the update card. That
/// is what the setting is for, but it means someone can go from 0.3.0 to 0.3.2 having never
/// seen a word about what changed. Comparing the running version against the last one that
/// ran is the only signal there is.
///
/// Pure, because the cases that matter are the ones that are awkward to reach by hand: a first
/// install must not claim to be an update, and a downgrade is still a change worth announcing.
enum UpdateAnnouncement {
    /// - Parameters:
    ///   - lastRun: the version recorded at the previous launch, or nil on a first run.
    ///   - current: the version running now.
    ///   - dismissed: the version whose announcement was already waved away.
    static func shouldAnnounce(lastRun: String?, current: String, dismissed: String?) -> Bool {
        // A first install is not an update. There is no "what's new" for someone who has never
        // seen the old one, and "Updated to 0.3.1" on first launch is simply false.
        guard let lastRun, !lastRun.isEmpty else { return false }
        guard lastRun != current else { return false }
        // Dismissing is per-version, so the next release announces itself again.
        return dismissed != current
    }
}

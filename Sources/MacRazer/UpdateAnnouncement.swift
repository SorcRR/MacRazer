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
    ///   - hasRunBefore: whether an older version of the app left any trace on this machine.
    ///     Consulted only when no version was recorded, which is true in two very different
    ///     situations: a genuinely new install, and an upgrade *from* a version that predates
    ///     this bookkeeping. Without it the release that introduces the feature is the one
    ///     release it stays silent for.
    static func shouldAnnounce(lastRun: String?,
                               current: String,
                               dismissed: String?,
                               hasRunBefore: Bool) -> Bool {
        // Dismissing is per-version, so the next release announces itself again.
        guard dismissed != current else { return false }
        if let lastRun, !lastRun.isEmpty { return lastRun != current }
        // A first install is not an update: there is no "what's new" for someone who has never
        // seen the old one, and "Updated to 0.3.1" on a first launch is simply false. But an
        // upgrade from a build that never recorded a version looks identical from here, and
        // only evidence that the app has run here before tells them apart.
        return hasRunBefore
    }

    /// The version whose announcement is outstanding after this launch, or nil.
    ///
    /// An announcement has to outlive the launch that noticed it. The card is set on the
    /// launch *after* an install, and a menu bar app that starts at login can go days without
    /// its popover being opened — so deriving it once and keeping it in memory means a reboot,
    /// a quit, or a crash in between loses it for good, on exactly the automatic-install path
    /// it exists to serve.
    ///
    /// - Parameter storedPending: an announcement carried over from an earlier launch.
    static func pending(lastRun: String?,
                        current: String,
                        dismissed: String?,
                        storedPending: String?,
                        hasRunBefore: Bool) -> String? {
        if shouldAnnounce(lastRun: lastRun, current: current,
                          dismissed: dismissed, hasRunBefore: hasRunBefore) {
            return current
        }
        // Still owed, and still about what is running. A pending announcement for some other
        // version is stale — you rolled back, or updated again before reading it — and the
        // version you are on now is the only one worth talking about.
        return storedPending == current ? current : nil
    }
}

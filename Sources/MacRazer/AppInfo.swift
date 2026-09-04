// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// What the app knows about itself. One place, because four files had grown their own read of
/// `CFBundleShortVersionString` and they didn't agree on the fallback — which mattered, since
/// one of those disagreements is deliberate (see below) and the rest were accidents.
enum AppInfo {
    /// The bundle's marketing version, or nil under `swift run`, which has no bundle.
    static var version: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// For showing a human. "dev" reads as what it is.
    static var displayVersion: String { version ?? "dev" }

    static var displayBuild: String { build ?? "—" }

    /// For `VersionCompare`. Deliberately **not** `displayVersion`: "0" sorts older than any
    /// real release, so a dev build always sees an update as available, whereas "dev" parses
    /// to 0 by accident rather than by intent and reads as a bug when you meet it.
    static var comparableVersion: String { version ?? "0" }
}

/// Every URL that identifies this project. Also one place: the repository host appeared in
/// four files, so a rename would have left the updater polling one place while the About
/// window linked to another — and nothing would have failed loudly, the update card would
/// just have quietly stopped finding releases.
enum ProjectLinks {
    static let repo = URL(string: "https://github.com/SorcRR/MacRazer")!
    static let site = URL(string: "https://sorcrr.github.io/MacRazer/")!
    static let tip = URL(string: "https://ko-fi.com/sorcrr")!
    static let developer = URL(string: "https://github.com/SorcRR")!

    static let issues = repo.appendingPathComponent("issues")
    /// GitHub's fixed "latest" shortcut; `Scripts/make-dmg.sh` keeps the asset name constant
    /// precisely so this URL never has to change.
    static let latestDMG = repo.appendingPathComponent("releases/latest/download/MacRazer.dmg")
    static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/SorcRR/MacRazer/releases/latest")!

    // Upstream, credited in the About window and NOTICE.md.
    static let openRazer = URL(string: "https://github.com/openrazer/openrazer")!
    static let cobraHyperSpeedPR = URL(string: "https://github.com/openrazer/openrazer/pull/2583")!
}

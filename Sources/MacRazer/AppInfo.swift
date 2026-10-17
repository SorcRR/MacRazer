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
/// Somewhere else entirely. `ProjectLinks` is every URL that identifies *this* project, and
/// putting an unrelated one in there would make that sentence false for whoever adds the next.
enum ElsewhereLinks {
    /// The About window's "For developers" section.
    static let hiveship = URL(string: "https://hiveship.app/")!
}

enum ProjectLinks {
    static let repo = URL(string: "https://github.com/SorcRR/MacRazer")!
    static let site = URL(string: "https://sorcrr.github.io/MacRazer/")!
    static let tip = URL(string: "https://ko-fi.com/sorcrr")!
    static let developer = URL(string: "https://github.com/SorcRR")!
    /// The homepage's section on usage stats: what's sent, and how to delete it.
    static let privacy = URL(string: "https://sorcrr.github.io/MacRazer/#privacy")!

    static let issues = repo.appendingPathComponent("issues")
    /// Where "Full release notes" goes: the popover shows a parsed summary, this is the
    /// unabridged original.
    static let latestRelease = repo.appendingPathComponent("releases/latest")
    /// One release's DMG, by version. The updater fetches the exact release it announced, not
    /// GitHub's "latest" pointer: the app picks the newest release itself, by version number,
    /// while GitHub picks "latest" by date or by hand, and the two can disagree (a hotfix for an
    /// older line published after a newer release). Pinning the download to the announced
    /// version means the card can never offer one version and install another.
    ///
    /// `tag` is the release's tag as GitHub reported it, when the last check recorded one. When
    /// it did not, the card having been restored from preferences at launch or read from a
    /// cache older than the field, the tag is rebuilt as `v<version>`, which is how
    /// `Scripts/release.sh` tags every release. `Scripts/make-dmg.sh` keeps the asset named
    /// `MacRazer.dmg` on every release.
    static func dmg(forVersion version: String, tag: String? = nil) -> URL {
        repo.appendingPathComponent("releases/download/\(tag ?? "v\(version)")/MacRazer.dmg")
    }
    /// The list, not `releases/latest`. The app shows the span between the version you are on
    /// and the one you are getting, and one release cannot describe a span.
    ///
    /// 20 because GitHub's JSON is about 6 KB per release once the author and asset objects
    /// are counted, so this is a ~120 KB ceiling on a once-a-day request. It covers roughly
    /// five years at this project's rate. Anyone further behind sees the most recent releases
    /// only, which is already more than anybody reads.
    ///
    /// `releases/latest` filtered drafts and prereleases on GitHub's side. The list does not,
    /// so that rule now lives in `ReleaseSpan` where it can be tested.
    static let releasesAPI =
        URL(string: "https://api.github.com/repos/SorcRR/MacRazer/releases?per_page=20")!

    // Upstream, credited in the About window and NOTICE.md.
    static let openRazer = URL(string: "https://github.com/openrazer/openrazer")!
    static let cobraHyperSpeedPR = URL(string: "https://github.com/openrazer/openrazer/pull/2583")!
}

/// The Worker in `worker/`, behind the device test's Send and the usage stats. Nil in any
/// build that wasn't given one: a clone, a fork, CI, `swift run`. Those builds hide and switch
/// off everything that would talk to it, so a build from someone else's checkout never
/// sends anything to the maintainer's Worker, or anywhere.
///
/// `Scripts/build-app.sh` writes the address into the bundle's Info.plist from DOMAIN in the
/// maintainer's private settings file (see `worker/README.md`). It is never in the repository.
enum WorkerEndpoint {
    static let infoKey = "MacRazerWorkerURL"
    /// For pointing a development build at `wrangler dev`: `MACRAZER_WORKER_URL=http://127.0.0.1:8787`.
    static let environmentKey = "MACRAZER_WORKER_URL"

    static let base: URL? = parse(ProcessInfo.processInfo.environment[environmentKey])
        ?? parse(Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)

    static var deviceReports: URL? { base?.appendingPathComponent("v1/device-report") }
    static var usageStats: URL? { base?.appendingPathComponent("v1/stats") }

    /// An origin and nothing else: https, or plain http only to this Mac for `wrangler dev`.
    /// Anything else counts as not configured rather than as somewhere to send reports.
    static func parse(_ value: String?) -> URL? {
        guard let value, let components = URLComponents(string: value),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        let local = host == "127.0.0.1" || host == "localhost"
        guard components.scheme == "https" || (components.scheme == "http" && local) else { return nil }
        var origin = components
        origin.path = ""
        return origin.url
    }
}

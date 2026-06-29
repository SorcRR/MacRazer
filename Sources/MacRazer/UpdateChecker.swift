// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Foundation

/// Polls GitHub Releases once a day for a newer MacRazer version, and lets the user download
/// and open the new DMG without leaving the app. No Sparkle/appcast — the app is unsigned and
/// distributed as a plain DMG, so "update" just means "fetch the latest DMG and let the user
/// drag it into Applications themselves," same as a manual download.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var latestVersion: String?
    @Published private(set) var isDownloading = false
    @Published var downloadError: String?

    private let releaseAPIURL = URL(string: "https://api.github.com/repos/SorcRR/MacRazer/releases/latest")!
    private let dmgURL = URL(string: "https://github.com/SorcRR/MacRazer/releases/latest/download/MacRazer.dmg")!
    private let checkInterval: TimeInterval = 24 * 60 * 60

    private static let dismissedKey = "dismissedUpdateVersion"
    private static let lastCheckKey = "lastUpdateCheckDate"

    private struct GitHubRelease: Decodable {
        let tag_name: String
    }

    private var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Checks at most once per `checkInterval`, regardless of how often this is called — safe to
    /// call on every launch and from a repeating timer.
    func checkForUpdatesIfDue() async {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < checkInterval { return }
        await checkForUpdatesNow()
    }

    /// Bypasses the throttle — used by `checkForUpdatesIfDue()` once due, and available for a
    /// manual "Check Now" action.
    func checkForUpdatesNow() async {
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        do {
            let (data, _) = try await URLSession.shared.data(from: releaseAPIURL)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remote = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            let dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey)
            if Self.isNewer(remote, than: currentVersion), remote != dismissed {
                latestVersion = remote
            } else {
                latestVersion = nil
            }
        } catch {
            // Silent: a failed background check shouldn't surface as an error — only an
            // explicit download attempt should show one.
        }
    }

    func dismiss(_ version: String) {
        UserDefaults.standard.set(version, forKey: Self.dismissedKey)
        latestVersion = nil
    }

    func downloadAndOpenDMG() async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadError = nil
        defer { isDownloading = false }
        do {
            let (tmpURL, _) = try await URLSession.shared.download(from: dmgURL)
            let dest = tmpURL.deletingLastPathComponent().appendingPathComponent("MacRazer.dmg")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            NSWorkspace.shared.open(dest)
        } catch {
            downloadError = "Download failed — check your connection and try again."
        }
    }

    /// Dotted-integer version compare (e.g. "0.1.10" > "0.1.9") — plain semver-ish strings only,
    /// no pre-release suffixes to worry about for this project.
    private static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}

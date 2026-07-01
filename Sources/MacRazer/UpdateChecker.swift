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
    private static let lastFoundKey = "lastFoundUpdateVersion"

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
        if let last, Date().timeIntervalSince(last) < checkInterval {
            // Within the throttle window, surface what the last successful check already
            // found — otherwise a relaunch forgets a known update for up to a day.
            restoreLastFound()
            return
        }
        await checkForUpdatesNow()
    }

    /// Bypasses the throttle — used by `checkForUpdatesIfDue()` once due, and available for a
    /// manual "Check Now" action.
    func checkForUpdatesNow() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: releaseAPIURL)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remote = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            // Only a *successful* check counts against the daily throttle: a failed one
            // (offline right after wake is common) should retry on the next opportunity,
            // not silence update notices for a day.
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            UserDefaults.standard.set(remote, forKey: Self.lastFoundKey)
            let dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey)
            if Self.isNewer(remote, than: currentVersion), remote != dismissed {
                latestVersion = remote
            } else {
                latestVersion = nil
            }
        } catch {
            // Silent: a failed background check shouldn't surface as an error — only an
            // explicit download attempt should show one. But do surface what the last
            // *successful* check found, or an offline relaunch hides a known update.
            restoreLastFound()
        }
    }

    /// Re-applies the newest remote version a past check found (newer-than-current and
    /// not-dismissed are re-evaluated, so updating or dismissing in the meantime clears it).
    private func restoreLastFound() {
        guard latestVersion == nil,
              let found = UserDefaults.standard.string(forKey: Self.lastFoundKey) else { return }
        let dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey)
        if Self.isNewer(found, than: currentVersion), found != dismissed {
            latestVersion = found
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

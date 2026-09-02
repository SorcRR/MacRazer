// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Where the running app bundle lives — the one fact "start at login" and the in-place
/// updater both have to agree on before they act.
///
/// Each feature writes down (or overwrites) a path that must still mean "MacRazer" later:
/// after a reboot for the login item, after the swap for the updater. Three locations break
/// that promise and are treated as "not installed yet":
///
/// - **a mounted disk image** (`/Volumes/…`) — the app is being run straight out of the DMG
///   without ever being dragged to Applications; the path is gone on eject, and the volume is
///   read-only besides;
/// - **app translocation** (`…/AppTranslocation/…`) — Gatekeeper's randomized read-only copy
///   of a still-quarantined app, discarded when it quits;
/// - **the temp directories** — a staging copy, never an installation.
///
/// A bundle that isn't an `.app` at all covers the remaining case: `swift run`, where
/// `Bundle.main` is the SwiftPM binary's directory in `.build`.
enum AppLocation {
    /// Locations that exist for one session, not for the next boot.
    private static let transientPrefixes = [
        "/Volumes/", "/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/",
    ]

    /// Whether `path` is somewhere a login item or an in-place update may point at.
    static func isStableInstall(_ path: String) -> Bool {
        // A trailing slash is legal in a bundle path and would defeat the suffix check.
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        guard p.hasPrefix("/"), p.hasSuffix(".app") else { return false }
        // Translocation mounts appear under /private/var/folders too, but the marker is what
        // makes the intent legible in a crash report or a log line.
        if p.contains("/AppTranslocation/") { return false }
        return !transientPrefixes.contains { p.hasPrefix($0) }
    }

    /// The running app's bundle when it is a real, installed `.app` — nil under `swift run`,
    /// from a mounted image, or when translocated.
    static var installedBundleURL: URL? {
        let url = Bundle.main.bundleURL
        return isStableInstall(url.path) ? url : nil
    }
}

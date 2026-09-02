// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Where the running app bundle lives — the one fact "start at login" and the in-place
/// updater both have to agree on before they act.
///
/// Each feature writes down (or overwrites) a path that must still mean "MacRazer" later:
/// after a reboot for the login item, after the swap for the updater. What breaks that
/// promise:
///
/// - **app translocation** (`…/AppTranslocation/…`) — Gatekeeper's randomized read-only copy
///   of a still-quarantined app, discarded when it quits;
/// - **the temp directories** — a staging copy, never an installation;
/// - **a read-only volume** — overwhelmingly a mounted disk image, i.e. the app run straight
///   out of the DMG without ever being dragged across.
///
/// A bundle that isn't an `.app` at all covers the remaining case: `swift run`, where
/// `Bundle.main` is the SwiftPM binary's directory in `.build`.
///
/// Note what is deliberately *not* here: a `/Volumes/` prefix. Mounted images live there, but
/// so do secondary internal volumes and external drives where people quite reasonably keep
/// their applications — banning the prefix outright told those users to "move MacRazer to
/// your Applications folder" when it already was in one. Read-only is the property that
/// actually separates a disk image from a disk.
enum AppLocation {
    /// Locations that exist for one session, not for the next boot.
    private static let transientPrefixes = [
        "/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/",
    ]

    /// The path-shape half of the test — pure, so it stays unit-testable. `installedBundleURL`
    /// adds the volume check, which needs the filesystem.
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
        guard isStableInstall(url.path), !isOnReadOnlyVolume(url) else { return nil }
        return url
    }

    /// A read-only volume can't hold an install we could update, and a login item pointing
    /// into one is pointing at something ejectable. An unreadable resource value is treated as
    /// writable: failing open keeps a working install working, and the updater checks
    /// writability again for itself before it touches anything.
    private static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }
}

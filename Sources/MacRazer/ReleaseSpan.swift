// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// One published release, as far as this app cares: a version and the notes that came with it.
struct RemoteRelease: Equatable, Codable {
    let version: String
    let body: String
    var isPrerelease: Bool = false
    var isDraft: Bool = false
}

/// Which releases to show someone, given where they are and where they are going.
///
/// The app used to ask GitHub for `releases/latest` and show that one body, whatever version
/// the reader was on. Someone who went from 0.3.0 straight to 0.4.1 was shown 0.4.1's notes,
/// which open by describing a bug in 0.4.0 that they never ran, and were told nothing about
/// the four mice and the features they had actually just gained. A release is not the unit
/// anyone cares about. The span between two versions is.
enum ReleaseSpan {
    /// Everything worth showing a user, newest first: real releases only, ordered by version
    /// rather than by the order GitHub happened to return them.
    ///
    /// Drafts are not published and prereleases are not offered by the updater, so neither
    /// belongs in notes about what you are getting. `releases/latest` applied both of these
    /// rules on GitHub's side; asking for the list means applying them here.
    static func publishable(_ releases: [RemoteRelease]) -> [RemoteRelease] {
        releases
            .filter { !$0.isDraft && !$0.isPrerelease && !$0.version.isEmpty }
            .sorted { VersionCompare.isNewer($0.version, than: $1.version) }
    }

    /// What you would gain by updating: everything newer than what you are running.
    static func newer(than current: String, in releases: [RemoteRelease]) -> [RemoteRelease] {
        publishable(releases).filter { VersionCompare.isNewer($0.version, than: current) }
    }

    /// What you just gained: everything after the version you were on, up to and including the
    /// one now running.
    ///
    /// `from` is nil when nothing was recorded, which is a first install or an upgrade from a
    /// build too old to have kept the value. There is no span to describe then, so this falls
    /// back to the single release you are on, which is the most that can honestly be claimed.
    static func between(from: String?, upToAndIncluding current: String,
                        in releases: [RemoteRelease]) -> [RemoteRelease] {
        let upTo = publishable(releases).filter { !VersionCompare.isNewer($0.version, than: current) }
        guard let from, !from.isEmpty else {
            return upTo.first.map { [$0] } ?? []
        }
        return upTo.filter { VersionCompare.isNewer($0.version, than: from) }
    }
}

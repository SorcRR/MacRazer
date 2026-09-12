// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

/// One release's notes, with the version they belong to.
///
/// The popover shows a span of releases, so each block needs to say which version it is. A
/// single release's notes carry no version of their own: the body is just prose.
struct VersionedNotes: Equatable, Identifiable {
    let version: String
    let notes: ReleaseNotes

    var id: String { version }
}

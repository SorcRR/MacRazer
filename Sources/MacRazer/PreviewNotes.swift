// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

/// Sample copy for the `render-*` commands.
///
/// The real v0.3.0 release body, so the previews show the notes page at the length releases
/// actually reach rather than at the length of a tidy sample. A `static let` rather than a
/// top-level `let` in `main.swift`: statics are lazy, so the menu bar app never touches it,
/// and `render-about` can reach it too.
enum PreviewNotes {
    static let releaseBody = """
MacRazer now starts at login and installs its own updates, with Settings and About windows to go with them.

### Added
- **Start MacRazer at login**, on by default. A menu bar battery meter that stops existing after every reboot isn't much of a battery meter.
- **"Update & Restart"** in the update card. When a new version is out, MacRazer downloads it, checks it, replaces itself and relaunches. No more dragging a DMG.
- **"Install updates automatically"**, off by default. It never starts while the popover or a window is open, since installing ends in a relaunch.
- **A Settings window**, reached from the right-click menu or the gear in the footer.
- **An About window**, with the licence and proper credit to OpenRazer.
- The **charging bolt fills the mouse icon and is yellow**, instead of a grey squiggle you had to look for.

### Fixed
- Builds no longer appear to hang at the codesigning step. macOS was showing a keychain prompt that a scripted build has nobody to click.

### Install
This build is unsigned, so first launch shows the standard Gatekeeper warning.

**Full changelog:** https://github.com/SorcRR/MacRazer/blob/master/CHANGELOG.md
"""
}

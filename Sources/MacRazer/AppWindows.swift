// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// A window the app can put on screen. Exists so callers can ask "is the user in one of our
/// windows?" without naming them.
///
/// That question has one caller and a sharp reason: an automatic update install ends in a
/// relaunch, so it must not start while the user is looking at something. It was originally
/// written as `popover.isShown || settingsWindow.isVisible` — which then had to be corrected
/// three times, and still missed Remap, Permissions, and About the moment About was added.
/// Enumerating windows at the call site is what kept going wrong; this makes adding a window
/// a matter of conforming it, not of remembering a predicate somewhere else.
@MainActor
protocol AppWindowPresenter: AnyObject {
    /// Whether this controller's window is currently on screen. False before `show()` has ever
    /// been called, since the window is built lazily.
    var isVisible: Bool { get }
}

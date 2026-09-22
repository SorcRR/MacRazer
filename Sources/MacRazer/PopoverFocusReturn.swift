// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

/// Whether closing the popover should give keyboard focus back to the app the user was in.
///
/// Opening the popover activates MacRazer, so its controls answer the first click. But the app
/// has no Dock icon and, once the popover is gone, usually no window either. Left alone it
/// would stay the active app with nothing on screen, and the next keystrokes would go nowhere.
/// So focus goes back where it came from, unless something about the close says the user
/// meant to stay, or has already moved on.
///
/// Pure, so every rule is testable. `AppDelegate` gathers the facts and acts on the verdict.
enum PopoverFocusReturn {
    struct Conditions: Equatable {
        /// The right-click menu is being tracked. Activating another app now would dismiss it.
        var appMenuOpen: Bool
        /// The popover is showing again, e.g. "Open Controls" from that menu.
        var popoverShown: Bool
        /// Something of the app's came up since the popover opened: one of its windows, or a
        /// system panel such as the colour picker. The close was on the way to it, and handing
        /// focus away would bury it, or dismiss it outright, since panels hide when their app
        /// stops being active.
        var windowOpened: Bool
        /// MacRazer is still the active app. If it is not, the user closed the popover by
        /// clicking into another app, which already has focus; taking it back would fight them.
        var appIsActive: Bool
        /// Some other app was frontmost when the popover opened, and it is still running.
        var hasPreviousApp: Bool
    }

    enum Verdict: Equatable {
        /// The popover session is not over yet. Keep the previous app for a later decision.
        case wait
        /// The session is over and focus stays where it is.
        case stay
        /// The session is over; activate the previous app.
        case returnFocus
    }

    static func verdict(_ c: Conditions) -> Verdict {
        // Checked first: deciding while the session is still going would spend the previous
        // app before the real end of it.
        if c.appMenuOpen || c.popoverShown { return .wait }
        guard c.hasPreviousApp, c.appIsActive, !c.windowOpened else { return .stay }
        return .returnFocus
    }
}

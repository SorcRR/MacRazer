// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class PopoverFocusReturnTests: XCTestCase {
    /// A plain close, by clicking the menu bar icon again or pressing Esc: nothing else open,
    /// MacRazer still active, and an app to go back to.
    private func verdict(
        menu: Bool = false, popover: Bool = false, window: Bool = false,
        active: Bool = true, previous: Bool = true
    ) -> PopoverFocusReturn.Verdict {
        PopoverFocusReturn.verdict(.init(
            appMenuOpen: menu, popoverShown: popover, windowOpened: window,
            appIsActive: active, hasPreviousApp: previous))
    }

    func testAPlainCloseHandsFocusBack() {
        // The bug this exists for: without it, keystrokes after closing the popover go nowhere.
        XCTAssertEqual(verdict(), .returnFocus)
    }

    func testWaitsWhileTheSessionIsStillGoing() {
        // Activating another app would dismiss the right-click menu mid-choice.
        XCTAssertEqual(verdict(menu: true), .wait)
        // "Open Controls" brought the popover back; its eventual close still needs the app.
        XCTAssertEqual(verdict(popover: true), .wait)
        // Not final yet even when a later check would say stay.
        XCTAssertEqual(verdict(menu: true, window: true), .wait)
        XCTAssertEqual(verdict(popover: true, active: false), .wait)
    }

    func testEachReasonToStayIsEnoughOnItsOwn() {
        for (name, v) in [
            ("closed on the way to one of the app's windows or panels", verdict(window: true)),
            ("closed by clicking into another app, which already has focus", verdict(active: false)),
            ("no other app to go back to", verdict(previous: false)),
        ] {
            XCTAssertEqual(v, .stay, "should have kept focus where it is: \(name)")
        }
    }
}

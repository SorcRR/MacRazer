// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit

/// Which of the menu bar icon's two controls a click opens: the popover, or the right-click menu.
enum StatusItemClick {
    /// Whether a click on the menu bar icon is the one for the right-click menu. The event type
    /// alone isn't enough: after the menu has run its own tracking inside a press, the next
    /// right-click's action can arrive without `NSApp.currentEvent` being that press, and the
    /// popover opened in place of the menu. The right button still being down settles it, as
    /// the action comes on the press.
    static func opensMenu(eventType: NSEvent.EventType?, pressedButtons: Int, control: Bool) -> Bool {
        eventType == .rightMouseDown || eventType == .rightMouseUp || pressedButtons & 0b10 != 0 || control
    }
}

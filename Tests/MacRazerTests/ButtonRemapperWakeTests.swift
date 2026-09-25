// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import XCTest
@testable import MacRazer

/// While the mouse is offline its remaps are paused, and the battery poll that notices it
/// coming back backs off the longer it's away. A press of a mapped button is the moment the
/// user needs the mapping, so it asks for a check straight away. Only paused presses are
/// driven here: an unpaused mapped press posts a real keystroke to the session.
final class ButtonRemapperWakeTests: XCTestCase {
    private let back = 3

    /// Whether the tap let the event through. Answered while `event` is still alive: the
    /// tap returns it unretained.
    @discardableResult
    private func press(_ remapper: ButtonRemapper, button: Int, type: CGEventType = .otherMouseDown) -> Bool {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                            mouseButton: CGMouseButton(rawValue: UInt32(button))!)!
        return remapper.handle(type: type, event: event) != nil
    }

    private final class Counter { var checks = 0 }

    private func pausedRemapper(_ counter: Counter) -> ButtonRemapper {
        let r = ButtonRemapper()
        r.setMappings([back: .keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy")])
        r.remappingPaused = true
        r.onPressWhilePaused = { counter.checks += 1 }
        return r
    }

    func testAMappedPressWhilePausedAsksForACheckAndPassesThrough() {
        let counter = Counter()
        let r = pausedRemapper(counter)
        XCTAssertTrue(press(r, button: back),
                      "paused, so the press goes through: it may not be our mouse")
        XCTAssertEqual(counter.checks, 1)
    }

    func testOnlyAMappedButtonDownAsks() {
        let counter = Counter()
        let r = pausedRemapper(counter)
        press(r, button: back, type: .otherMouseUp)
        press(r, button: 4) // not mapped
        XCTAssertEqual(counter.checks, 0, "a release, or a button with no mapping, says nothing about our mouse")
    }

    func testBasiliskSideButtonsAreConfigurableBeforeFirstPress() {
        let remapper = ButtonRemapper()
        remapper.setActiveDevice("00ba")

        XCTAssertEqual(remapper.suggestedButtons, [3, 4])
        XCTAssertTrue(remapper.seenButtons.isEmpty,
                      "suggested controls are not claimed to have been physically detected")
    }
}

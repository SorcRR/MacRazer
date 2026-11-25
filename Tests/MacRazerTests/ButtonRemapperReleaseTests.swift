// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import XCTest
@testable import MacRazer

/// A mapped button's release goes the way its press went: swallowed after a swallowed press,
/// through after a press the app saw. Otherwise an app can see a press without its release
/// and keep the button held down. Synthetic events into `handle`, with the actions caught by
/// `actionEmitter` instead of posted, so nothing here needs Accessibility or reaches the
/// session.
final class ButtonRemapperReleaseTests: XCTestCase {
    private let back = 3
    private let copy = RemapAction.keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy")

    private final class Emitted {
        var actions: [RemapAction] = []
        var pausedPresses = 0
    }

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    /// A remapper with Back on Copy, whose actions land in `emitted`.
    private func remapper(_ emitted: Emitted, name: String = #function) -> ButtonRemapper {
        let suite = "MacRazerTests.ButtonRemapperRelease.\(name)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let r = ButtonRemapper(defaults: defaults, actionEmitter: { emitted.actions.append($0) })
        r.setMappings([back: copy])
        r.onPressWhilePaused = { emitted.pausedPresses += 1 }
        return r
    }

    /// Whether the tap let the event through. Answered while `event` is still alive: the
    /// tap returns it unretained.
    @discardableResult
    private func send(_ r: ButtonRemapper, _ type: CGEventType, button: Int? = nil) -> Bool {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                            mouseButton: CGMouseButton(rawValue: UInt32(button ?? back))!)!
        return r.handle(type: type, event: event) != nil
    }

    /// A mapped button's press and release are both swallowed, and the action fires once.
    func testAMappedButtonsPressAndReleaseAreSwallowed() {
        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertFalse(send(r, .otherMouseDown))
        XCTAssertFalse(send(r, .otherMouseUp))
        XCTAssertEqual(emitted.actions, [copy])
    }

    /// A press goes through while paused, and asks for the check that unpauses
    /// (`onPressWhilePaused`), which can land while the button is still held. Its release must
    /// go through too: swallowed, the app that saw the press would keep the button held down.
    func testAPressLetThroughWhilePausedHasItsReleaseLetThroughAfterUnpausing() {
        let emitted = Emitted()
        let r = remapper(emitted)
        r.remappingPaused = true
        XCTAssertTrue(send(r, .otherMouseDown))
        XCTAssertEqual(emitted.pausedPresses, 1)
        r.remappingPaused = false
        XCTAssertTrue(send(r, .otherMouseUp), "the release of a press the app saw")
        XCTAssertEqual(emitted.actions, [])

        XCTAssertFalse(send(r, .otherMouseDown), "the next press is the mapping's again")
        XCTAssertFalse(send(r, .otherMouseUp))
        XCTAssertEqual(emitted.actions, [copy])
    }

    /// The other way round: pausing between a swallowed press and its release still swallows
    /// the release, so no app sees a release of a press it never saw.
    func testPausingMidPressStillSwallowsTheRelease() {
        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertFalse(send(r, .otherMouseDown))
        r.remappingPaused = true
        XCTAssertFalse(send(r, .otherMouseUp), "its press was swallowed")
        XCTAssertTrue(send(r, .otherMouseDown), "the next press is paused, and goes through")
        XCTAssertTrue(send(r, .otherMouseUp), "and so does its release")
        XCTAssertEqual(emitted.actions, [copy])
    }

    /// A remap to None between the press and the release still swallows the release of the
    /// swallowed press.
    func testRemappingMidPressStillSwallowsTheRelease() {
        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertFalse(send(r, .otherMouseDown))
        r.setAction(.passthrough, for: back)
        XCTAssertFalse(send(r, .otherMouseUp), "its press was swallowed")
        XCTAssertTrue(send(r, .otherMouseDown), "None now")
        XCTAssertTrue(send(r, .otherMouseUp))
        XCTAssertEqual(emitted.actions, [copy])
    }

    /// A release whose press the tap never saw (pressed before the tap was installed, or while
    /// it was off) followed a press the app saw, so it goes through, and fires nothing.
    func testAReleaseWithoutASeenPressGoesThrough() {
        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertTrue(send(r, .otherMouseUp))
        XCTAssertEqual(emitted.actions, [])
    }
}

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

    // MARK: The DPI button's F20

    private let playPause = RemapAction.mediaKey(code: 16, name: "Play / Pause")

    /// A Basilisk V3 X over Bluetooth whose DPI button types F20 for Play / Pause, confirmed
    /// on the mouse, with no gesture yet.
    private func dpiRemapper(_ emitted: Emitted, name: String = #function) -> ButtonRemapper {
        let r = remapper(emitted, name: name)
        r.setActiveDevice("PM2533", deviceID: 0x00BA)
        r.saveDpiSoftwareAction(playPause)
        r.confirmDpiBridge(binding: .softwareBridge)
        return r
    }

    /// Whether the tap let F20 through.
    @discardableResult
    private func sendF20(_ r: ButtonRemapper, down: Bool, repeating: Bool = false) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 90, keyDown: down)!
        if repeating { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return r.handle(type: down ? .keyDown : .keyUp, event: event) != nil
    }

    /// Adding the first gesture or removing the last reinstalls the tap. With the DPI button
    /// held right then, its F20 release must still be swallowed: an app that never saw F20 go
    /// down mustn't see it come up.
    func testTheDpiButtonsReleaseIsSwallowedAcrossATapReinstall() {
        let emitted = Emitted()
        let r = dpiRemapper(emitted)
        let before = r.wantedEventMask

        XCTAssertFalse(sendF20(r, down: true))
        r.makeGesture(back)
        XCTAssertNotEqual(r.wantedEventMask, before, "a new mask, so the tap is reinstalled")
        XCTAssertTrue(ButtonRemapper.includesKeyboardEvents(r.wantedEventMask), "still with the keys")
        r.tapReplaced(mask: r.wantedEventMask)
        XCTAssertFalse(sendF20(r, down: true, repeating: true), "a repeat follows its press")
        XCTAssertFalse(sendF20(r, down: false), "the release of the press before the reinstall")
        XCTAssertEqual(emitted.actions, [playPause])

        XCTAssertFalse(sendF20(r, down: true))
        r.setAction(.passthrough, for: back)
        r.tapReplaced(mask: r.wantedEventMask)
        XCTAssertFalse(sendF20(r, down: false), "and removing the gesture again")
        XCTAssertEqual(emitted.actions, [playPause, playPause])
    }

    /// A tap without the keys (none asked for, macOS refused them, or no tap at all) never
    /// sees the release, which reaches the app. Forgotten, so the next F20 release a tap with
    /// the keys sees, of a press an app saw, goes through.
    func testATapWithoutTheKeysForgetsTheHeldDpiButton() {
        for mask in [ButtonRemapper.eventMask(keyboard: false, gestures: true), CGEventMask(0)] {
            let emitted = Emitted()
            let r = dpiRemapper(emitted, name: "\(#function)-\(mask)")
            XCTAssertFalse(sendF20(r, down: true))
            r.tapReplaced(mask: mask)
            XCTAssertTrue(sendF20(r, down: false), "mask \(mask)")
        }
    }

    /// A press whose release went by unseen (the tap off for a moment) can't take the next
    /// press's action: a fresh press starts over.
    func testAFreshDpiPressFiresAfterALostRelease() {
        let emitted = Emitted()
        let r = dpiRemapper(emitted)
        XCTAssertFalse(sendF20(r, down: true))
        XCTAssertFalse(sendF20(r, down: true), "no release came between")
        XCTAssertFalse(sendF20(r, down: false))
        XCTAssertEqual(emitted.actions, [playPause, playPause])
    }

    /// F20's repeats and release go the way its press went, whatever changed in between: a
    /// press let through while paused keeps its repeats and release going through after
    /// unpausing, and a swallowed one keeps them swallowed after pausing.
    func testTheDpiButtonsRepeatsAndReleaseFollowItsPress() {
        let emitted = Emitted()
        let r = dpiRemapper(emitted)
        r.remappingPaused = true
        XCTAssertTrue(sendF20(r, down: true))
        r.remappingPaused = false
        XCTAssertTrue(sendF20(r, down: true, repeating: true))
        XCTAssertTrue(sendF20(r, down: false), "the release of a press the app saw")
        XCTAssertEqual(emitted.actions, [])

        XCTAssertFalse(sendF20(r, down: true))
        r.remappingPaused = true
        XCTAssertFalse(sendF20(r, down: true, repeating: true))
        XCTAssertFalse(sendF20(r, down: false), "its press was swallowed")
        XCTAssertEqual(emitted.actions, [playPause])
    }
}

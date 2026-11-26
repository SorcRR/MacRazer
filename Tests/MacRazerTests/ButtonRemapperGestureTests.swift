// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import XCTest
@testable import MacRazer

/// A gesture button through the tap: synthetic events into `handle`, with the actions caught
/// by `actionEmitter` instead of posted, so nothing here needs Accessibility or reaches the
/// session.
final class ButtonRemapperGestureTests: XCTestCase {
    private let back = 3
    private let bindings = GestureBindings(
        click: .mediaKey(code: 16, name: "Play / Pause"),
        up: .keystroke(keyCode: 126, modifiers: 0, name: "Up"),
        down: .keystroke(keyCode: 125, modifiers: 0, name: "Down"),
        left: .keystroke(keyCode: 123, modifiers: 0, name: "Left"),
        right: .keystroke(keyCode: 124, modifiers: 0, name: "Right"))

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

    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "MacRazerTests.ButtonRemapperGesture.\(name)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A remapper with Back as a gesture, whose actions land in `emitted`.
    private func remapper(_ emitted: Emitted, name: String = #function) -> ButtonRemapper {
        let r = ButtonRemapper(defaults: defaults(name), actionEmitter: { emitted.actions.append($0) })
        r.setMappings([back: .gesture(bindings)])
        r.onPressWhilePaused = { emitted.pausedPresses += 1 }
        return r
    }

    /// Whether the tap let the event through. Answered while `event` is still alive: the
    /// tap returns it unretained.
    @discardableResult
    private func send(_ r: ButtonRemapper, _ type: CGEventType, button: Int? = nil,
                      dx: Int64 = 0, dy: Int64 = 0) -> Bool {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                            mouseButton: CGMouseButton(rawValue: UInt32(button ?? back))!)!
        event.setIntegerValueField(.mouseEventDeltaX, value: dx)
        event.setIntegerValueField(.mouseEventDeltaY, value: dy)
        return r.handle(type: type, event: event) != nil
    }

    // MARK: The hold

    /// Apps must see none of a gesture: not the press, not the drags (an app that never saw
    /// the button go down shouldn't see it drag), not the release.
    func testTheGestureButtonsPressDragsAndReleaseAreAllSwallowed() {
        let r = remapper(Emitted())
        XCTAssertFalse(send(r, .otherMouseDown), "the press")
        XCTAssertFalse(send(r, .otherMouseDragged, dx: 10), "a drag while held")
        XCTAssertFalse(send(r, .otherMouseUp), "the release")
    }

    /// A swipe fires its direction's action once, while the hand is still moving, and the
    /// release after it is not also a click.
    func testASwipeFiresItsActionOnceAndNoClick() {
        let emitted = Emitted()
        let r = remapper(emitted)
        send(r, .otherMouseDown)
        send(r, .otherMouseDragged, dy: -30)
        XCTAssertEqual(emitted.actions, [], "30 points is not a swipe yet")
        send(r, .otherMouseDragged, dy: -30)
        XCTAssertEqual(emitted.actions, [bindings.up], "fired during the movement, upward as y shrinks")
        send(r, .otherMouseDragged, dy: -200)
        send(r, .otherMouseDragged, dx: 200)
        send(r, .otherMouseUp)
        XCTAssertEqual(emitted.actions, [bindings.up], "once per hold, and no click after a swipe")
    }

    /// A press and release in place is the click, fired at the release: only then is it known
    /// that no swipe is coming.
    func testAPressWithoutASwipeFiresTheClickOnRelease() {
        let emitted = Emitted()
        let r = remapper(emitted)
        send(r, .otherMouseDown)
        send(r, .otherMouseDragged, dx: 12, dy: 8)
        XCTAssertEqual(emitted.actions, [], "nothing on the press")
        send(r, .otherMouseUp)
        XCTAssertEqual(emitted.actions, [bindings.click])
    }

    /// While the mouse is offline a gesture button behaves as every mapped button does today:
    /// it goes through (it may be another mouse's) and its press asks for a check.
    func testWhilePausedTheGestureButtonPassesThrough() {
        let emitted = Emitted()
        let r = remapper(emitted)
        r.remappingPaused = true
        XCTAssertTrue(send(r, .otherMouseDown))
        XCTAssertTrue(send(r, .otherMouseDragged, dy: 100))
        XCTAssertTrue(send(r, .otherMouseUp))
        XCTAssertEqual(emitted.pausedPresses, 1, "the press asks whether the mouse is back")
        XCTAssertEqual(emitted.actions, [], "no swipe, no click")
    }

    /// Drags are the hot path: with no hold, or for another button, they go straight through.
    func testDragsThatAreNotTheHoldsPassThrough() {
        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertTrue(send(r, .otherMouseDragged, dy: 100), "no hold in progress")
        send(r, .otherMouseDown)
        XCTAssertTrue(send(r, .otherMouseDragged, button: 2, dy: 100), "the wheel button's drag, held alongside")
        XCTAssertEqual(emitted.actions, [], "another button's movement is not the gesture's")
    }

    // MARK: Ending a hold

    /// Pausing mid-hold ends it: the release fires nothing, and is swallowed as its press was,
    /// so no app sees a release of a press it never saw (Back's release can be what
    /// navigates).
    func testPausingEndsTheHold() {
        let emitted = Emitted()
        let r = remapper(emitted)
        send(r, .otherMouseDown)
        XCTAssertNotNil(r.gestureHold)
        r.remappingPaused = true
        XCTAssertNil(r.gestureHold)
        XCTAssertFalse(send(r, .otherMouseUp), "the release of a swallowed press")
        XCTAssertEqual(emitted.actions, [])
        XCTAssertTrue(send(r, .otherMouseDown), "the next press is paused, and goes through")
        XCTAssertTrue(send(r, .otherMouseUp), "and so does its release")
    }

    /// The reverse, and the likelier: a press goes through while paused, and asks for the
    /// check that unpauses (`onPressWhilePaused`), which can land while the button is still
    /// held, as it is through a swipe. Its release must go through too: swallowed, the app
    /// that saw the press would keep the button held down. And nothing fires for it.
    func testAPressLetThroughWhilePausedHasItsReleaseLetThroughAfterUnpausing() {
        let emitted = Emitted()
        let r = remapper(emitted)
        r.remappingPaused = true
        XCTAssertTrue(send(r, .otherMouseDown))
        XCTAssertEqual(emitted.pausedPresses, 1)
        r.remappingPaused = false
        XCTAssertNil(r.gestureHold, "no hold for a press that went through")
        XCTAssertTrue(send(r, .otherMouseDragged, dy: -100), "its drags are the app's")
        XCTAssertTrue(send(r, .otherMouseUp), "the release of a press the app saw")
        XCTAssertEqual(emitted.actions, [], "no swipe, no click")

        XCTAssertFalse(send(r, .otherMouseDown), "the next press is the gesture's again")
        XCTAssertFalse(send(r, .otherMouseUp))
        XCTAssertEqual(emitted.actions, [bindings.click])
    }

    /// A release whose press the tap never saw (pressed before the tap was installed, or while
    /// it was off) was preceded by a press the app saw, so it goes through, and fires nothing.
    func testAReleaseWithoutASeenPressGoesThrough() {
        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertTrue(send(r, .otherMouseUp))
        XCTAssertEqual(emitted.actions, [])
    }

    /// A keystroke button's release follows its press the same way: a remap to None between
    /// them still swallows the release of the swallowed press, and the press fired once.
    func testAKeystrokeButtonsReleaseFollowsItsPress() {
        let emitted = Emitted()
        let r = remapper(emitted)
        let copy = RemapAction.keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy")
        r.setAction(copy, for: 4)
        XCTAssertFalse(send(r, .otherMouseDown, button: 4))
        r.setAction(.passthrough, for: 4)
        XCTAssertFalse(send(r, .otherMouseUp, button: 4), "its press was swallowed")
        XCTAssertEqual(emitted.actions, [copy])
        XCTAssertTrue(send(r, .otherMouseDown, button: 4), "None now")
        XCTAssertTrue(send(r, .otherMouseUp, button: 4))
    }

    /// A new press ends a hold, so one whose release went missing can't keep swallowing drags.
    func testANewPressEndsTheHold() {
        let emitted = Emitted()
        let r = remapper(emitted)
        send(r, .otherMouseDown)
        XCTAssertNotNil(r.gestureHold)
        send(r, .otherMouseDown, button: 4) // not mapped
        XCTAssertNil(r.gestureHold)
        XCTAssertTrue(send(r, .otherMouseDragged, dy: 100), "no hold to feed")
        XCTAssertFalse(send(r, .otherMouseUp), "still a gesture button, whose release is always swallowed")
        XCTAssertEqual(emitted.actions, [], "the hold was gone, so no click either")
    }

    /// When the tap is switched off for a moment, events go by unseen, the release among them.
    func testADisabledTapEndsTheHold() {
        let emitted = Emitted()
        let r = remapper(emitted)
        send(r, .otherMouseDown)
        XCTAssertNotNil(r.gestureHold)
        let event = CGEvent(source: nil)!
        _ = r.handle(type: .tapDisabledByTimeout, event: event)
        XCTAssertNil(r.gestureHold)
        send(r, .otherMouseUp)
        XCTAssertEqual(emitted.actions, [], "no click from a hold that was dropped")
    }

    /// Changing the button's mapping ends its hold: the hold was started with the old one.
    /// The release still follows its press, which was swallowed.
    func testChangingTheMappingEndsTheHold() {
        let emitted = Emitted()
        let r = remapper(emitted)
        send(r, .otherMouseDown)
        XCTAssertNotNil(r.gestureHold)
        r.setAction(.passthrough, for: back)
        XCTAssertNil(r.gestureHold)
        XCTAssertFalse(send(r, .otherMouseUp), "None now, but its press was swallowed: so is the release")
        XCTAssertEqual(emitted.actions, [])
        XCTAssertTrue(send(r, .otherMouseDown), "the next press is None's")
        XCTAssertTrue(send(r, .otherMouseUp))

        r.setMappings([back: .gesture(bindings)])
        send(r, .otherMouseDown)
        XCTAssertNotNil(r.gestureHold)
        r.setMappings([:])
        XCTAssertNil(r.gestureHold, "a new table (a profile) ends it too")
    }

    // MARK: The hold without events

    /// The hold is apart from the events that drive it: movement named for another trigger
    /// isn't its, it ends once, and a cancelled hold has nothing to end and no click.
    func testTheHoldCanBeDrivenWithoutMouseButtonEvents() {
        let emitted = Emitted()
        let r = ButtonRemapper(defaults: defaults(), actionEmitter: { emitted.actions.append($0) })
        let button6 = 5
        r.beginGesture(bindings, trigger: button6)
        XCTAssertFalse(r.moveGesture(dx: 0, dy: 80, trigger: back), "movement for another trigger")
        XCTAssertTrue(r.moveGesture(dx: 0, dy: 80, trigger: button6))
        XCTAssertEqual(emitted.actions, [bindings.down])
        XCTAssertTrue(r.endGesture(trigger: button6))
        XCTAssertFalse(r.endGesture(trigger: button6), "already ended")
        XCTAssertEqual(emitted.actions, [bindings.down], "no click after a swipe")

        r.beginGesture(bindings, trigger: button6)
        r.cancelGesture()
        XCTAssertFalse(r.endGesture(trigger: button6), "cancelled, so nothing to end and no click")
        XCTAssertEqual(emitted.actions, [bindings.down])
    }

    // MARK: Actions

    /// A gesture inside a gesture is never offered; if one turns up in saved data, its slot
    /// does nothing rather than start a hold within a hold.
    func testAGestureNestedInAGestureIsInert() {
        let emitted = Emitted()
        let r = ButtonRemapper(defaults: defaults(), actionEmitter: { emitted.actions.append($0) })
        var nested = bindings
        nested.up = .gesture(bindings)
        nested.click = .gesture(bindings)
        r.setMappings([back: .gesture(nested)])
        send(r, .otherMouseDown)
        send(r, .otherMouseDragged, dy: -80)
        send(r, .otherMouseUp)
        send(r, .otherMouseDown)
        send(r, .otherMouseUp)
        XCTAssertEqual(emitted.actions, [], "neither the swipe nor the click fires anything")

        r.setGestureAction(.gesture(bindings), for: .down, of: back)
        XCTAssertEqual(r.gestureBindings(for: back)?.down, bindings.down, "and the editor can't nest one")
    }

    /// The defaults follow the MX gesture button: Mission Control up and Launchpad down, and
    /// the Spaces the way a trackpad drags the desktop, so left brings the next Space (Space
    /// Right) and right the previous one (Space Left). The click keeps the button's own click.
    func testTheDefaultsAreMissionControlLaunchpadAndSpacesThatFollowTheHand() {
        func preset(_ id: String) -> RemapAction? { ButtonRemapper.presets.first { $0.id == id }?.action }
        let defaults = GestureBindings.defaults(for: back)
        XCTAssertEqual(defaults.up, preset("missionControl"))
        XCTAssertEqual(defaults.down, .launchpad)
        XCTAssertEqual(defaults.left, preset("spaceRight"), "left brings the next Space")
        XCTAssertEqual(defaults.right, preset("spaceLeft"), "right brings the previous Space")
        XCTAssertEqual(defaults.click, .mouseButton(button: back, name: "Back Button"))
        XCTAssertEqual(GestureBindings.defaults(for: 2).click, .mouseButton(button: 2, name: "Middle Click"),
                       "the same action as the menu's Middle Click")
        XCTAssertEqual(GestureBindings.defaults(for: 5).click, .mouseButton(button: 5, name: "Button 6"))
    }

    /// With the defaults a swipe down opens Launchpad once, as soon as it reaches 50 points,
    /// and a swipe left and right fire the next and the previous Space.
    func testTheDefaultSwipesFireLaunchpadAndTheSpaces() {
        let emitted = Emitted()
        let r = ButtonRemapper(defaults: defaults(), actionEmitter: { emitted.actions.append($0) })
        r.setMappings([back: .gesture(.defaults(for: back))])
        func preset(_ id: String) -> RemapAction { ButtonRemapper.presets.first { $0.id == id }!.action }
        send(r, .otherMouseDown)
        send(r, .otherMouseDragged, dy: 30)
        XCTAssertEqual(emitted.actions, [])
        send(r, .otherMouseDragged, dy: 30)
        send(r, .otherMouseDragged, dy: 300)
        send(r, .otherMouseUp)
        XCTAssertEqual(emitted.actions, [.launchpad], "once, during the movement")
        for dx: Int64 in [-60, 60] {
            send(r, .otherMouseDown)
            send(r, .otherMouseDragged, dx: dx)
            send(r, .otherMouseUp)
        }
        XCTAssertEqual(emitted.actions, [.launchpad, preset("spaceRight"), preset("spaceLeft")])
    }

    /// The editor says how a gesture is made, in plain words.
    func testTheEditorSaysHowAGestureIsMade() {
        let text = RemapView.gestureEditorExplanation()
        XCTAssertTrue(text.hasPrefix("Hold the button and move the mouse up, down, left or right."))
        XCTAssertTrue(text.contains("without moving to click"))
        XCTAssertFalse(text.contains("\u{2014}"), "no em dash")
    }

    /// Choosing Gesture… sets the defaults once; choosing it again only reopens the editor,
    /// so the choices made there stay.
    func testChoosingGestureAgainKeepsItsChoices() {
        let r = ButtonRemapper(defaults: defaults())
        r.makeGesture(back)
        XCTAssertEqual(r.gestureBindings(for: back), .defaults(for: back))
        r.setGestureAction(.doubleClick, for: .up, of: back)
        r.makeGesture(back)
        XCTAssertEqual(r.gestureBindings(for: back)?.up, .doubleClick)
        XCTAssertEqual(r.actionLabel(for: back), "Gesture")

        r.setGestureAction(.doubleClick, for: .up, of: 4)
        XCTAssertNil(r.gestureBindings(for: 4), "a slot of a button that isn't a gesture changes nothing")
    }

    /// The click re-posts the gesture button's own number. Made with `postSource`, it carries
    /// the tag the tap skips: otherwise the tap would take it for another press of the
    /// gesture button and swallow it. Back and Forward must come out as themselves, not as a
    /// middle click.
    func testTheRepostedClickIsTaggedAndPassesTheTap() throws {
        let emitted = Emitted()
        let r = remapper(emitted)
        for button in [2, 3, 4] {
            let events = ButtonRemapper.mouseClickEvents(button: button, at: .zero, source: try XCTUnwrap(r.postSource))
            XCTAssertEqual(events.map(\.type), [.otherMouseDown, .otherMouseUp], "button \(button)")
            for event in events {
                XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), Int64(button), "button \(button)")
                XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 1, "button \(button)")
                XCTAssertNotNil(r.handle(type: event.type, event: event), "button \(button) passes the tap")
            }
        }
        XCTAssertNil(r.gestureHold, "the re-posted press doesn't start a hold")
        XCTAssertEqual(emitted.actions, [])
    }

    // MARK: Saving

    /// A gesture survives the trip through UserDefaults, the way a relaunch reads it back.
    func testAGestureIsSavedAndReadBack() {
        let shared = defaults()
        let custom = GestureBindings(
            click: .doubleClick,
            up: .keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy  ⌘C"),
            down: .mediaKey(code: 7, name: "Mute"),
            left: .mouseButton(button: 3, name: "Back Button"),
            right: .passthrough)
        let first = ButtonRemapper(defaults: shared)
        first.setActiveDevice("GESTURE-TEST")
        first.setAction(.gesture(custom), for: back)
        first.setAction(.doubleClick, for: 4)

        let second = ButtonRemapper(defaults: shared)
        second.setActiveDevice("GESTURE-TEST")
        XCTAssertEqual(second.mappings, [back: .gesture(custom), 4: .doubleClick])
    }

    /// When a mouse first connects its data is saved under its product id, and moves to its
    /// serial once that's read (`MouseController.migratePerDeviceData`). A gesture goes with
    /// it whole, in the mouse buttons' table and in a profile.
    func testAGestureMovesFromThePidKeyToTheSerialKey() throws {
        let oldKey = "test-pid-\(UUID().uuidString)", newKey = "test-serial-\(UUID().uuidString)"
        let standard = UserDefaults.standard
        let keys = ["buttonMappings-\(oldKey)", "buttonMappings-\(newKey)"]
        defer {
            keys.forEach(standard.removeObject(forKey:))
            ProfileStore.removeStorage(forDevice: oldKey)
            ProfileStore.removeStorage(forDevice: newKey)
        }
        let table: [Int: RemapAction] = [back: .gesture(bindings), 4: .doubleClick]
        standard.set(try JSONEncoder().encode(table), forKey: "buttonMappings-\(oldKey)")
        let profile = MouseProfile(name: "Swipes", dpi: 1600, pollRate: 1000, brightness: 50, effect: "",
                                   color: RGB(r: 0, g: 0, b: 0), buttonMappings: table)
        ProfileStore.save([profile], forDevice: oldKey)

        MouseController.migratePerDeviceData(from: oldKey, to: newKey)

        let r = ButtonRemapper(defaults: standard)
        r.setActiveDevice(newKey)
        XCTAssertEqual(r.mappings, table)
        XCTAssertEqual(ProfileStore.profiles(forDevice: newKey).map(\.buttonMappings), [table])
        XCTAssertNil(standard.object(forKey: "buttonMappings-\(oldKey)"))
        XCTAssertEqual(ProfileStore.profiles(forDevice: oldKey), [])
    }

    // MARK: The tap's events

    /// Drags come at the mouse's polling rate: the tap asks for them only while a gesture
    /// needs them.
    func testTheTapAsksForDragsOnlyForAGesture() {
        let drag = CGEventMask(1) << CGEventType.otherMouseDragged.rawValue
        let down = CGEventMask(1) << CGEventType.otherMouseDown.rawValue
        let plain = ButtonRemapper.eventMask(keyboard: false, gestures: false)
        XCTAssertEqual(plain & drag, 0)
        XCTAssertNotEqual(plain & down, 0)
        XCTAssertNotEqual(ButtonRemapper.eventMask(keyboard: false, gestures: true) & drag, 0)
        XCTAssertNotEqual(plain, ButtonRemapper.eventMask(keyboard: false, gestures: true),
                          "a different mask, so adding a gesture reinstalls the tap")
        XCTAssertTrue(ButtonRemapper.includesKeyboardEvents(ButtonRemapper.eventMask(keyboard: true, gestures: true)))
        XCTAssertFalse(ButtonRemapper.includesKeyboardEvents(ButtonRemapper.eventMask(keyboard: false, gestures: true)))
    }

    /// The drags are asked for while any gesture needs them and no longer: the mask the tap
    /// should have follows every way the table changes, one button, a whole profile, and a
    /// switch to another mouse with its own table.
    func testTheWantedMaskFollowsTheTableEveryWayItChanges() {
        let drag = CGEventMask(1) << CGEventType.otherMouseDragged.rawValue
        let shared = defaults()
        let r = ButtonRemapper(defaults: shared)
        r.setActiveDevice("WITH-GESTURE")
        XCTAssertEqual(r.wantedEventMask & drag, 0)
        r.makeGesture(back)
        XCTAssertNotEqual(r.wantedEventMask & drag, 0, "one button made a gesture")
        r.setAction(.passthrough, for: back)
        XCTAssertEqual(r.wantedEventMask & drag, 0, "and put back")
        r.setMappings([4: .gesture(bindings)])
        XCTAssertNotEqual(r.wantedEventMask & drag, 0, "a profile with a gesture")

        r.setActiveDevice("WITHOUT-GESTURE")
        XCTAssertEqual(r.wantedEventMask & drag, 0, "another mouse, with no gesture saved")
        r.setActiveDevice("WITH-GESTURE")
        XCTAssertNotEqual(r.wantedEventMask & drag, 0, "back to the one with a gesture")
        r.setActiveDevice(nil)
        XCTAssertEqual(r.wantedEventMask & drag, 0, "no mouse, no table")
    }

    /// When macOS refuses the keyboard tap, the fallback drops only the keys. Gestures keep
    /// their drags, and the next check finds the mask it asks for instead of reinstalling the
    /// tap on every change.
    func testTheKeyboardFallbackKeepsTheDrags() {
        for gestures in [false, true] {
            XCTAssertEqual(ButtonRemapper.eventMask(keyboard: true, gestures: gestures) & ~ButtonRemapper.keyboardEventsMask,
                           ButtonRemapper.eventMask(keyboard: false, gestures: gestures), "gestures: \(gestures)")
        }
    }
}

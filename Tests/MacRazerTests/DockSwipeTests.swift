// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CoreGraphics
import XCTest
@testable import MacRazer

/// The swipes that follow the pointer: which slots are system swipes, the rules that turn a
/// hold's movement into a dock swipe (`DockSwipeTracker`), and the events that carry it to
/// the Dock. Nothing here is posted: the events are only built and read back, and the
/// poster's `send` is a recorder.
final class DockSwipeTests: XCTestCase {
    /// Small round numbers, so progress reads as points: 1 point is 0.001 sideways, 0.002
    /// up or down.
    private let scale = DockSwipe.Scale(horizontal: 0.001, vertical: 0.002)

    private func preset(_ id: String) -> RemapAction { ButtonRemapper.presets.first { $0.id == id }!.action }

    private let copy = RemapAction.keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy  ⌘C")

    /// All four system swipes, each on its own side: up Mission Control, down App Exposé, left
    /// Space Left, right Space Right.
    private let allFour = SystemSwipeSlots(up: .missionControl, down: .appExpose, left: .spaceLeft, right: .spaceRight)

    private func tracker(_ slots: SystemSwipeSlots? = nil) -> DockSwipeTracker {
        DockSwipeTracker(slots: slots ?? allFour, scale: scale, at: 0)
    }

    // MARK: Which slots

    /// The four presets are recognised as what the menu put in the slot, so saved gestures
    /// and the defaults follow the pointer with nothing to migrate. The same keys recorded as
    /// a custom shortcut, and every other action, stay what they were.
    func testOnlyTheFourPresetsAreSystemSwipes() {
        XCTAssertEqual(SystemSwipe(preset("missionControl")), .missionControl)
        XCTAssertEqual(SystemSwipe(preset("appExpose")), .appExpose)
        XCTAssertEqual(SystemSwipe(preset("spaceLeft")), .spaceLeft)
        XCTAssertEqual(SystemSwipe(preset("spaceRight")), .spaceRight)
        XCTAssertEqual(SystemSwipeSlots(.defaults(click: .passthrough)),
                       SystemSwipeSlots(up: .missionControl, down: nil, left: .spaceRight, right: .spaceLeft),
                       "the defaults: Launchpad down isn't a swipe, and the Spaces are swapped")

        let recorded = RemapAction.keystroke(keyCode: 126, modifiers: CGEventFlags.maskControl.rawValue, name: "⌃↑")
        for action in [recorded, copy, preset("screenshot"), .passthrough, .doubleClick,
                       .mediaKey(code: 16, name: "Play / Pause"), .mouseButton(button: 3, name: "Back Button"),
                       .launchpad, .gesture(.defaults(click: .passthrough))] {
            XCTAssertNil(SystemSwipe(action), action.label)
        }
        XCTAssertTrue(SystemSwipeSlots(GestureBindings(click: preset("missionControl"), up: copy, down: .passthrough,
                                                       left: .doubleClick, right: recorded)).isEmpty,
                      "the click is never a swipe")
    }

    /// App Exposé is a dock swipe only while the Dock's trackpad gesture for it is on; the
    /// setting reads as off unless it says yes, as macOS has it out of the box.
    func testAppExposeIsASwipeOnlyWhileItsTrackpadGestureIsOn() {
        XCTAssertEqual(DockGestures.appExposeKey, "showAppExposeGestureEnabled")
        XCTAssertEqual(DockGestures.dockDomain, "com.apple.dock")
        XCTAssertTrue(DockGestures.isOn(true as NSNumber))
        XCTAssertTrue(DockGestures.isOn(1 as NSNumber))
        XCTAssertFalse(DockGestures.isOn(false as NSNumber))
        XCTAssertFalse(DockGestures.isOn(0 as NSNumber))
        XCTAssertFalse(DockGestures.isOn(nil), "never set: off, the default")
        XCTAssertFalse(DockGestures.isOn("1" as NSString), "not a number")

        XCTAssertEqual(allFour.removing(.appExpose),
                       SystemSwipeSlots(up: .missionControl, down: nil, left: .spaceLeft, right: .spaceRight))
        XCTAssertEqual(SystemSwipeSlots(up: .appExpose, down: .appExpose).removing(.appExpose), SystemSwipeSlots())
        XCTAssertEqual(allFour.removing(.missionControl).up, nil)
    }

    /// A preset saved without the Fn and numeric pad flags (as before #143) is still the
    /// preset: those flags are added when it's posted anyway.
    func testAPresetSavedWithoutFnIsStillRecognised() {
        let plain = RemapAction.keystroke(keyCode: 124, modifiers: CGEventFlags.maskControl.rawValue,
                                          name: "Space Right  ⌃→")
        XCTAssertEqual(SystemSwipe(plain), .spaceRight)
        let otherKeys = RemapAction.keystroke(keyCode: 124, modifiers: CGEventFlags.maskCommand.rawValue,
                                              name: "Space Right  ⌃→")
        XCTAssertNil(SystemSwipe(otherKeys), "the name alone isn't enough")
    }

    // MARK: The dead zone and the axis

    /// A click's drift must stay a click: nothing begins inside the dead zone, however the
    /// movement adds up there.
    func testNothingBeginsInsideTheDeadZone() {
        var t = tracker()
        XCTAssertNil(t.move(dx: 8, dy: 6, at: 0.01))
        XCTAssertNil(t.move(dx: 4, dy: -12, at: 0.02))
        XCTAssertNil(t.move(dx: -12, dy: 6, at: 0.03), "back at (0, 0)")
        XCTAssertNil(t.move(dx: 0, dy: -DockSwipeTracker.deadZone, at: 0.04), "exactly the dead zone is still inside")
        XCTAssertEqual(t.state, .undecided)
        XCTAssertFalse(t.leftDeadZone)
        XCTAssertNil(t.end(at: 0.05), "nothing to end")
    }

    /// Past the dead zone the swipe begins at once, and the movement so far counts, so the
    /// desktop starts where the pointer is.
    func testLeavingTheDeadZoneBeginsTheSwipeWithTheMovementSoFar() {
        var t = tracker()
        XCTAssertNil(t.move(dx: -10, dy: 3, at: 0.01))
        let began = t.move(dx: -5, dy: 0, at: 0.02)
        XCTAssertEqual(began?.kind, .horizontal)
        XCTAssertEqual(began?.phase, .began)
        XCTAssertEqual(began?.progress ?? 0, -0.015, accuracy: 1e-12)
        XCTAssertEqual(began?.velocity, 0)
        XCTAssertTrue(t.isSwiping)
        XCTAssertEqual(t.swipe, .spaceLeft)
    }

    /// Left heads for the previous Space and up opens Mission Control, as the slots say, and
    /// the other two the other way. Getting a sign wrong would swap them.
    func testEachDirectionHeadsForItsSlot() {
        let moves: [(dx: Double, dy: Double, kind: DockSwipe.Kind, sign: Double)] = [
            (-20, 0, .horizontal, -1), (20, 0, .horizontal, 1), (0, -20, .vertical, -1), (0, 20, .vertical, 1),
        ]
        for move in moves {
            var t = tracker()
            let began = t.move(dx: move.dx, dy: move.dy, at: 0.01)
            XCTAssertEqual(began?.kind, move.kind, "(\(move.dx), \(move.dy))")
            XCTAssertEqual(began?.phase, .began)
            XCTAssertEqual(began.map { $0.progress.sign == .minus ? -1 : 1 }, move.sign, "(\(move.dx), \(move.dy))")
        }
        var up = tracker()
        XCTAssertEqual(up.move(dx: 0, dy: -20, at: 0.01)?.progress ?? 0, -0.04, accuracy: 1e-12,
                       "vertical progress has its own scale")
    }

    /// The sign comes from the slots, not the screen: with left and right swapped, as the
    /// defaults have them, moving left heads for the Space on the right, and with up and down
    /// swapped, moving up opens App Exposé.
    func testSwappedSlotsFlipTheSign() {
        let swapped = SystemSwipeSlots(up: .appExpose, down: .missionControl, left: .spaceRight, right: .spaceLeft)
        var left = tracker(swapped)
        XCTAssertEqual(left.move(dx: -20, dy: 0, at: 0.01)?.progress ?? 0, 0.02, accuracy: 1e-12)
        XCTAssertEqual(left.swipe, .spaceRight)
        var up = tracker(swapped)
        XCTAssertEqual(up.move(dx: 0, dy: -20, at: 0.01)?.progress ?? 0, 0.04, accuracy: 1e-12)
        XCTAssertEqual(up.swipe, .appExpose)
    }

    /// A slot can hold a swipe of the other axis: moving up towards Space Left heads for the
    /// Space on the left, at the horizontal scale.
    func testASwipeCanSitOnTheOtherAxis() {
        var t = tracker(SystemSwipeSlots(up: .spaceLeft, down: .spaceRight))
        let began = t.move(dx: 0, dy: -20, at: 0.01)
        XCTAssertEqual(began?.kind, .horizontal)
        XCTAssertEqual(began?.progress ?? 0, -0.02, accuracy: 1e-12)
        XCTAssertEqual(t.move(dx: 0, dy: 50, at: 0.02)?.progress ?? 0, 0.03, accuracy: 1e-12,
                       "and back past the start into Space Right")
    }

    /// The larger axis is locked for the rest of the hold: the other one is ignored, as a
    /// trackpad ignores a sideways drift while Mission Control opens.
    func testTheAxisIsLockedForTheRestOfTheHold() {
        var t = tracker()
        XCTAssertEqual(t.move(dx: 20, dy: 15, at: 0.01)?.kind, .horizontal, "the larger axis")
        XCTAssertNil(t.move(dx: 0, dy: -300, at: 0.02), "up is no longer Mission Control")
        XCTAssertEqual(t.progress, 0.02, accuracy: 1e-12)
        XCTAssertEqual(t.move(dx: 10, dy: -50, at: 0.03)?.progress ?? 0, 0.03, accuracy: 1e-12, "only dx counts")

        var diagonal = tracker()
        XCTAssertEqual(diagonal.move(dx: -13, dy: 13, at: 0.01)?.kind, .horizontal,
                       "an exact diagonal is horizontal, as for the discrete swipe")
    }

    /// Any other action the pointer heads for leaves the hold to the discrete swipe: no dock
    /// swipe, however far it goes.
    func testAnotherActionLeavesTheHoldDiscrete() {
        var t = tracker(SystemSwipeSlots(up: .missionControl, right: .spaceRight))
        XCTAssertNil(t.move(dx: -20, dy: 0, at: 0.01), "left is Copy or None")
        XCTAssertEqual(t.state, .discrete)
        XCTAssertTrue(t.leftDeadZone)
        XCTAssertNil(t.move(dx: 200, dy: 0, at: 0.02), "not even back into Space Right")
        XCTAssertNil(t.move(dx: 0, dy: -200, at: 0.03))
        XCTAssertNil(t.end(at: 0.04))
    }

    // MARK: Following the pointer

    /// Every movement moves the swipe, as long as the frames don't come closer together than
    /// `minimumFrameInterval`. The end carries the latest progress, so none of it is lost.
    func testChangesFollowTheMovementAtMostEveryFrameInterval() {
        XCTAssertLessThan(DockSwipeTracker.minimumFrameInterval, 0.005)
        XCTAssertGreaterThan(DockSwipeTracker.minimumFrameInterval, 0.002)
        var t = tracker()
        XCTAssertEqual(t.move(dx: 20, dy: 0, at: 0)?.phase, .began)
        XCTAssertEqual(t.move(dx: 5, dy: 0, at: 0.005)?.progress ?? 0, 0.025, accuracy: 1e-12)
        XCTAssertEqual(t.move(dx: 5, dy: 0, at: 0.010)?.progress ?? 0, 0.03, accuracy: 1e-12)
        XCTAssertNil(t.move(dx: 5, dy: 0, at: 0.012), "too soon after the last frame")
        XCTAssertEqual(t.progress, 0.035, accuracy: 1e-12, "but counted")
        XCTAssertEqual(t.move(dx: 5, dy: 0, at: 0.015)?.progress ?? 0, 0.04, accuracy: 1e-12)
        XCTAssertNil(t.move(dx: 5, dy: 0, at: 0.017))
        XCTAssertNil(t.move(dx: 0, dy: 0, at: 0.025), "a zero movement is no change either")
        XCTAssertEqual(t.end(at: 0.025)?.progress ?? 0, 0.045, accuracy: 1e-12)
    }

    /// Moving back reverses the swipe, past the start into the opposite slot's swipe when it
    /// is the same one the other way: on from the previous Space towards the next.
    func testMovingBackGoesOnIntoTheOppositeSwipe() {
        var t = tracker()
        XCTAssertEqual(t.move(dx: -20, dy: 0, at: 0.01)?.progress ?? 0, -0.02, accuracy: 1e-12)
        XCTAssertEqual(t.move(dx: 15, dy: 0, at: 0.02)?.progress ?? 0, -0.005, accuracy: 1e-12)
        XCTAssertEqual(t.move(dx: 35, dy: 0, at: 0.03)?.progress ?? 0, 0.03, accuracy: 1e-12)
    }

    /// When the opposite slot is anything else (an action, None, or the other kind of
    /// swipe), the swipe can be taken back but stops at the start.
    func testWithoutTheSameSwipeOppositeTheProgressStopsAtTheStart() {
        let cases: [(String, SystemSwipeSlots)] = [
            ("another action", SystemSwipeSlots(left: .spaceLeft)),
            ("the other kind", SystemSwipeSlots(left: .spaceLeft, right: .missionControl)),
            ("the same swipe", SystemSwipeSlots(left: .spaceLeft, right: .spaceLeft)),
        ]
        for (name, slots) in cases {
            var t = tracker(slots)
            XCTAssertEqual(t.move(dx: -20, dy: 0, at: 0.01)?.progress ?? 0, -0.02, accuracy: 1e-12, name)
            XCTAssertEqual(t.move(dx: 50, dy: 0, at: 0.02)?.progress, 0, "\(name): stops at the start")
            XCTAssertNil(t.move(dx: 30, dy: 0, at: 0.03), "\(name): and stays there")
            XCTAssertEqual(t.move(dx: -10, dy: 0, at: 0.04)?.progress ?? 0, -0.01, accuracy: 1e-12,
                           "\(name): the way back out counts at once")
        }
    }

    // MARK: The end

    /// The end carries the velocity of the hand, in progress per second, so a flick can
    /// finish the swipe. Steady movement reads as its own speed.
    func testTheEndCarriesTheVelocity() throws {
        var t = tracker()
        var time = 1.0
        _ = t.move(dx: 20, dy: 0, at: time)
        for _ in 0..<40 { // 10 points every 10 ms: 1000 points per second, for 0.4 s
            time += 0.01
            _ = t.move(dx: 10, dy: 0, at: time)
        }
        var released = t
        let end = try XCTUnwrap(released.end(at: time))
        XCTAssertEqual(end.phase, .ended)
        XCTAssertEqual(end.kind, .horizontal)
        XCTAssertEqual(end.progress, 0.42, accuracy: 1e-9)
        XCTAssertEqual(end.velocity, 1.0, accuracy: 0.01, "1000 points per second at 0.001 a point")
        XCTAssertNil(released.end(at: time), "ended once")
        XCTAssertNil(released.move(dx: 10, dy: 0, at: time + 0.01), "nothing after the end")

        // The velocity fades while the pointer is still before the release: a stop leaves
        // the swipe to its progress.
        var stopped = t
        let late = try XCTUnwrap(stopped.end(at: time + 0.2))
        XCTAssertEqual(late.phase, .ended)
        XCTAssertLessThan(late.velocity, 0.02)
        XCTAssertGreaterThan(late.velocity, 0)
    }

    /// The other way, the velocity is negative too: towards the previous Space.
    func testTheVelocityHasTheProgressSign() throws {
        var t = tracker()
        var time = 0.0
        for _ in 0..<40 {
            time += 0.008
            _ = t.move(dx: 0, dy: -8, at: time)
        }
        let end = try XCTUnwrap(t.end(at: time))
        XCTAssertEqual(end.phase, .ended)
        XCTAssertLessThan(end.progress, 0)
        XCTAssertEqual(end.velocity, -2.0, accuracy: 0.05, "1000 points per second at 0.002 a point, upward")
    }

    /// A hand on its way back towards the start when it lets go wants the swipe undone, as
    /// on a trackpad; so does one that ends where it started.
    func testComingBackCancelsTheSwipe() throws {
        var back = tracker()
        var time = 0.0
        for dx in Array(repeating: -10.0, count: 10) + Array(repeating: 10.0, count: 5) {
            time += 0.01
            _ = back.move(dx: dx, dy: 0, at: time)
        }
        let end = try XCTUnwrap(back.end(at: time))
        XCTAssertEqual(end.phase, .cancelled)
        XCTAssertEqual(end.progress, -0.05, accuracy: 1e-12, "still short of the start")
        XCTAssertGreaterThan(end.velocity, 0, "moving back")

        var atStart = tracker(SystemSwipeSlots(left: .spaceLeft))
        _ = atStart.move(dx: -20, dy: 0, at: 0.01)
        _ = atStart.move(dx: 20, dy: 0, at: 0.02)
        XCTAssertEqual(atStart.end(at: 0.5)?.phase, .cancelled)
    }

    /// A hold that stops early cancels its swipe, with no velocity, once.
    func testCancelEndsTheSwipeOnce() {
        var t = tracker()
        XCTAssertNil(t.cancel(), "nothing began")
        _ = t.move(dx: 0, dy: 30, at: 0.01)
        let cancel = t.cancel()
        XCTAssertEqual(cancel?.kind, .vertical)
        XCTAssertEqual(cancel?.phase, .cancelled)
        XCTAssertEqual(cancel?.progress ?? 0, 0.06, accuracy: 1e-12)
        XCTAssertEqual(cancel?.velocity, 0)
        XCTAssertEqual(t.state, .finished)
        XCTAssertNil(t.cancel())
        XCTAssertNil(t.end(at: 1))
        XCTAssertNil(t.move(dx: 0, dy: 30, at: 0.02))
    }

    // MARK: The scale

    /// A Space is the screen's width and the gap after it, so the desktop slides with the
    /// pointer; how much progress that is depends on how many Spaces there are. Mission
    /// Control opens over the screen's height.
    func testTheScaleFollowsTheScreenAndItsSpaces() {
        let size = CGSize(width: 1440, height: 900)
        let width = 1440 + DockSwipe.Scale.spaceGap
        XCTAssertEqual(DockSwipe.Scale.screen(size: size, spaces: 1).horizontal, 2 / width, accuracy: 1e-15)
        XCTAssertEqual(DockSwipe.Scale.screen(size: size, spaces: 2).horizontal, 2 / width, accuracy: 1e-15)
        XCTAssertEqual(DockSwipe.Scale.screen(size: size, spaces: 3).horizontal, 1.5 / width, accuracy: 1e-15)
        XCTAssertEqual(DockSwipe.Scale.screen(size: size, spaces: 5).horizontal, 1.25 / width, accuracy: 1e-15)
        XCTAssertEqual(DockSwipe.Scale.screen(size: size, spaces: nil).horizontal, 1.5 / width, accuracy: 1e-15,
                       "unknown: three")
        XCTAssertEqual(DockSwipe.Scale.screen(size: size, spaces: 4).vertical, 1 / 900, accuracy: 1e-15)
        XCTAssertEqual(DockSwipe.Scale.screen(size: .zero, spaces: 2).vertical, 1, "no screen divides by nothing")
    }

    // MARK: The events

    private func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }

    /// A frame is two events: the dock swipe itself (type 30), then a plain gesture event
    /// (type 29). Each field the Dock reads is read back here. Getting one wrong fails
    /// silently on a real Mac: nothing moves.
    func testAFramesEventsCarryTheDockSwipeFields() throws {
        let userData: Int64 = 0x52415A45
        let frame = DockSwipe.Frame(kind: .horizontal, phase: .changed, progress: -0.375)
        let events = DockSwipe.events(for: frame, userData: userData)
        XCTAssertEqual(events.count, 2)
        let swipe = try XCTUnwrap(events.first), companion = try XCTUnwrap(events.last)

        XCTAssertEqual(swipe.type.rawValue, 30)
        XCTAssertEqual(swipe.getIntegerValueField(field(55)), 30)
        XCTAssertEqual(swipe.getIntegerValueField(field(110)), 23, "kIOHIDEventTypeDockSwipe")
        XCTAssertEqual(swipe.getIntegerValueField(field(132)), 2, "changed")
        XCTAssertEqual(swipe.getIntegerValueField(field(134)), 2)
        XCTAssertEqual(swipe.getIntegerValueField(field(123)), 1, "horizontal")
        XCTAssertEqual(swipe.getIntegerValueField(field(165)), 1)
        XCTAssertEqual(swipe.getDoubleValueField(field(119)), Double(Float32(bitPattern: 1)))
        XCTAssertEqual(swipe.getDoubleValueField(field(124)), -0.375)
        let bits = UInt32(truncatingIfNeeded: swipe.getIntegerValueField(field(135)))
        XCTAssertEqual(Float32(bitPattern: bits), -0.375, "the progress again, as a float's bits")
        XCTAssertEqual(swipe.getIntegerValueField(field(136)), 0)
        XCTAssertEqual(swipe.getDoubleValueField(field(129)), 0, "no velocity before the end")
        XCTAssertEqual(swipe.getIntegerValueField(field(41)), 33231)
        XCTAssertEqual(swipe.getIntegerValueField(.eventSourceUserData), userData)

        XCTAssertEqual(companion.type.rawValue, 29)
        XCTAssertEqual(companion.getIntegerValueField(field(110)), 0, "no gesture of its own")
        XCTAssertEqual(companion.getIntegerValueField(field(41)), 33231)
        XCTAssertEqual(companion.getIntegerValueField(.eventSourceUserData), userData)
    }

    /// The end carries the velocity in both of its fields; a vertical swipe its own kind and
    /// the inverted flag its direction was checked with.
    func testAnEndCarriesTheVelocityAndAVerticalSwipeItsKind() throws {
        let frame = DockSwipe.Frame(kind: .vertical, phase: .ended, progress: 0.5, velocity: -2.25)
        let swipe = try XCTUnwrap(DockSwipe.events(for: frame, userData: 0).first)
        XCTAssertEqual(swipe.getIntegerValueField(field(132)), 4, "ended")
        XCTAssertEqual(swipe.getIntegerValueField(field(123)), 2, "vertical")
        XCTAssertEqual(swipe.getIntegerValueField(field(165)), 2)
        XCTAssertEqual(swipe.getDoubleValueField(field(119)), Double(Float32(bitPattern: 2)))
        XCTAssertEqual(swipe.getIntegerValueField(field(136)), 1)
        XCTAssertEqual(swipe.getDoubleValueField(field(129)), -2.25)
        XCTAssertEqual(swipe.getDoubleValueField(field(130)), -2.25)

        let cancelled = DockSwipe.Frame(kind: .horizontal, phase: .cancelled, progress: 0.1)
        XCTAssertEqual(DockSwipe.events(for: cancelled, userData: 0).first?.getIntegerValueField(field(132)), 8)
        let began = DockSwipe.Frame(kind: .horizontal, phase: .began, progress: 0.1)
        XCTAssertEqual(DockSwipe.events(for: began, userData: 0).first?.getIntegerValueField(field(132)), 1)
    }

    // MARK: The poster

    private final class Sent { var events: [CGEvent] = [] }

    /// The poster sends both events of each frame, the swipe first. Each end goes out again
    /// twice later, in case the Dock missed it, and the next swipe's start stops the repeats
    /// that haven't gone yet: a late end would cut that swipe short.
    func testThePosterSendsEachFrameAndRepeatsTheEnd() {
        let sent = Sent()
        let poster = DockSwipePoster(userData: 7, send: { sent.events.append($0) })
        poster.post(DockSwipe.Frame(kind: .horizontal, phase: .began, progress: 0.1))
        poster.post(DockSwipe.Frame(kind: .horizontal, phase: .changed, progress: 0.2))
        XCTAssertEqual(sent.events.map(\.type.rawValue), [30, 29, 30, 29])
        XCTAssertEqual(poster.repeatTimers, [], "nothing to repeat before the end")

        poster.post(DockSwipe.Frame(kind: .horizontal, phase: .ended, progress: 0.2, velocity: 1))
        XCTAssertEqual(sent.events.count, 6)
        XCTAssertEqual(poster.repeatTimers.count, DockSwipePoster.endRepeats.count)
        let first = poster.repeatTimers[0]
        first.fire()
        XCTAssertEqual(sent.events.count, 8, "the end again")
        XCTAssertEqual(sent.events.suffix(2).map { $0.getIntegerValueField(CGEventField(rawValue: 132)!) }, [4, 0])
        first.fire()
        XCTAssertEqual(sent.events.count, 8, "each repeat goes once")

        let waiting = poster.repeatTimers
        XCTAssertEqual(waiting.count, 1)
        poster.post(DockSwipe.Frame(kind: .vertical, phase: .began, progress: -0.1))
        XCTAssertEqual(poster.repeatTimers, [])
        XCTAssertEqual(waiting.first?.isValid, false, "stopped, not only forgotten")
        waiting.first?.fire()
        XCTAssertEqual(sent.events.count, 10, "the new swipe's start, and no late end after it")
        XCTAssertEqual(sent.events.suffix(2).map(\.type.rawValue), [30, 29])
    }
}

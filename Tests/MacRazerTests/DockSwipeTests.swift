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
        let poster = DockSwipePoster(userData: 7, method: .eventFields, send: { sent.events.append($0) })
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

    // MARK: The method

    /// macOS 26 and earlier read the CGEvent fields, whatever private calls this Mac has (they
    /// aren't even looked up there). macOS 27 and later attach an IOHIDEvent, and have no method
    /// at all, so the presets stay shortcuts, when one of its calls is missing.
    func testTheMethodFollowsTheMacOSVersionAndTheCalls() {
        var asked = false
        let notAsked: () -> String? = { asked = true; return "SLEventSetIOHIDEvent (SkyLight)" }
        XCTAssertEqual(DockSwipe.method(majorVersion: 26, missingSymbol: notAsked()), .eventFields)
        XCTAssertEqual(DockSwipe.method(majorVersion: 14, missingSymbol: notAsked()), .eventFields)
        XCTAssertFalse(asked, "an earlier macOS never looks the private calls up")
        XCTAssertEqual(DockSwipe.method(majorVersion: 27, missingSymbol: nil), .attachedHIDEvent)
        XCTAssertEqual(DockSwipe.method(majorVersion: 28, missingSymbol: nil), .attachedHIDEvent)
        XCTAssertNil(DockSwipe.method(majorVersion: 27, missingSymbol: "SLEventSetIOHIDEvent (SkyLight)"))

        // This Mac, whichever it is.
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if major < 27 {
            XCTAssertEqual(DockSwipe.method, .eventFields)
        } else {
            XCTAssertEqual(DockSwipe.method, DockSwipe.AttachedEvent.missingSymbol == nil ? .attachedHIDEvent : nil)
        }
        XCTAssertEqual(DockSwipe.isSupported, DockSwipe.method != nil)
    }

    /// Natural scrolling is on unless stored as off: the key isn't written until the setting
    /// is first changed.
    func testNaturalScrollingIsOnUnlessStoredOff() {
        XCTAssertTrue(DockGestures.isNaturalScrolling(nil))
        XCTAssertTrue(DockGestures.isNaturalScrolling(NSNumber(value: true)))
        XCTAssertTrue(DockGestures.isNaturalScrolling(NSNumber(value: 1)))
        XCTAssertFalse(DockGestures.isNaturalScrolling(NSNumber(value: false)))
        XCTAssertFalse(DockGestures.isNaturalScrolling(NSNumber(value: 0)))
        XCTAssertTrue(DockGestures.isNaturalScrolling("yes"), "not a number: the default")
    }

    // MARK: The attached IOHIDEvent (macOS 27)

    /// The payload of a frame: the phase in the flags' top byte, the kind as the motion, and
    /// the progress signed for macOS 27, flipped while Natural scrolling is on. The velocity
    /// rides only on an end, signed the same way as the progress.
    func testTheAttachedPayloadDescribesTheFrame() {
        let changed = DockSwipe.Frame(kind: .horizontal, phase: .changed, progress: -0.375)
        let natural = DockSwipe.HIDPayload(changed, naturalScrolling: true)
        XCTAssertEqual(natural.flags, 2 << 24, "changed")
        XCTAssertEqual(natural.motion, 1, "horizontal")
        XCTAssertEqual(natural.progress, 0.375, "flipped while Natural scrolling is on")
        XCTAssertNil(natural.velocity, "no velocity before the end")
        XCTAssertEqual(DockSwipe.HIDPayload(changed, naturalScrolling: false).progress, -0.375, "kept while it is off")

        let ended = DockSwipe.Frame(kind: .vertical, phase: .ended, progress: 0.5, velocity: -2.25)
        let end = DockSwipe.HIDPayload(ended, naturalScrolling: true)
        XCTAssertEqual(end.flags, 4 << 24)
        XCTAssertEqual(end.motion, 2, "vertical")
        XCTAssertEqual(end.progress, -0.5)
        XCTAssertEqual(end.velocity, 2.25, "the velocity follows the progress")
        XCTAssertEqual(DockSwipe.HIDPayload(ended, naturalScrolling: false).velocity, -2.25)

        let began = DockSwipe.Frame(kind: .horizontal, phase: .began, progress: 0.1)
        XCTAssertEqual(DockSwipe.HIDPayload(began, naturalScrolling: true).flags, 1 << 24)
        let cancelled = DockSwipe.Frame(kind: .horizontal, phase: .cancelled, progress: 0.1)
        XCTAssertEqual(DockSwipe.HIDPayload(cancelled, naturalScrolling: true).flags, 8 << 24)
        XCTAssertEqual(DockSwipe.HIDPayload(cancelled, naturalScrolling: true).velocity, 0, "a cancel's end carries its 0")

        XCTAssertEqual(DockSwipe.HIDPayload.motionField, 0x17_0001)
        XCTAssertEqual(DockSwipe.HIDPayload.progressField, 0x17_0002)
        XCTAssertEqual(DockSwipe.HIDPayload.flavorField, 0x17_0005)
        XCTAssertEqual(DockSwipe.HIDPayload.velocityFields, [0x9_0000, 0x9_0001])
    }

    /// Reads back what an event's attached IOHIDEvent says, with private calls these tests
    /// look up themselves. Nil when one is missing, and the test skips.
    private struct HIDReader {
        typealias Copy = @convention(c) (CGEvent) -> UnsafeMutableRawPointer?
        typealias GetType = @convention(c) (UnsafeMutableRawPointer) -> UInt32
        typealias GetFlags = @convention(c) (UnsafeMutableRawPointer) -> UInt32
        typealias GetPhase = @convention(c) (UnsafeMutableRawPointer) -> UInt16
        typealias GetInteger = @convention(c) (UnsafeMutableRawPointer, UInt32) -> CFIndex
        typealias GetDouble = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Double
        typealias GetChildren = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?

        struct Event {
            let type: UInt32, flags: UInt32, phase: UInt16
            let integers: [UInt32: Int], doubles: [UInt32: Double]
            let children: [Event]
        }

        let copy: Copy, type: GetType, flags: GetFlags, phase: GetPhase
        let integer: GetInteger, double: GetDouble, children: GetChildren

        init?() {
            guard let ioKit = dlopen(DockSwipe.AttachedEvent.ioKitPath, RTLD_LAZY),
                  let skyLight = dlopen(DockSwipe.AttachedEvent.skyLightPath, RTLD_LAZY),
                  let copy = dlsym(skyLight, "SLEventCopyIOHIDEvent"), let type = dlsym(ioKit, "IOHIDEventGetType"),
                  let flags = dlsym(ioKit, "IOHIDEventGetEventFlags"), let phase = dlsym(ioKit, "IOHIDEventGetPhase"),
                  let integer = dlsym(ioKit, "IOHIDEventGetIntegerValue"),
                  let double = dlsym(ioKit, "IOHIDEventGetDoubleValue"),
                  let children = dlsym(ioKit, "IOHIDEventGetChildren") else { return nil }
            self.copy = unsafeBitCast(copy, to: Copy.self)
            self.type = unsafeBitCast(type, to: GetType.self)
            self.flags = unsafeBitCast(flags, to: GetFlags.self)
            self.phase = unsafeBitCast(phase, to: GetPhase.self)
            self.integer = unsafeBitCast(integer, to: GetInteger.self)
            self.double = unsafeBitCast(double, to: GetDouble.self)
            self.children = unsafeBitCast(children, to: GetChildren.self)
        }

        /// SLEventCopyIOHIDEvent follows the Copy rule: released here.
        func read(_ event: CGEvent, integers: [UInt32], doubles: [UInt32]) -> Event? {
            guard let hid = copy(event) else { return nil }
            defer { Unmanaged<AnyObject>.fromOpaque(hid).release() }
            return read(hid, integers: integers, doubles: doubles)
        }

        private func read(_ hid: UnsafeMutableRawPointer, integers: [UInt32], doubles: [UInt32]) -> Event {
            var kids: [Event] = []
            if let array = children(hid)?.takeUnretainedValue() {
                for index in 0..<CFArrayGetCount(array) {
                    let child = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(array, index)!)
                    kids.append(read(child, integers: [], doubles: DockSwipe.HIDPayload.velocityFields))
                }
            }
            return Event(type: type(hid), flags: flags(hid), phase: phase(hid),
                         integers: Dictionary(uniqueKeysWithValues: integers.map { ($0, integer(hid, $0)) }),
                         doubles: Dictionary(uniqueKeysWithValues: doubles.map { ($0, double(hid, $0)) }),
                         children: kids)
        }
    }

    /// The attached-event tests run only where the app itself uses that method: macOS 27 and
    /// later with every private call present (`DockSwipe.method`). The calls exist on older
    /// macOS too, but how they behave there (whether the attach copies the IOHIDEvent, as these
    /// tests assume) was only ever measured on 27, and the app never calls them below it. So
    /// on macOS 26 and on CI's older runners they skip instead of risking a crash.
    private func skipUnlessAttachedMethod() throws {
        guard DockSwipe.method == .attachedHIDEvent else {
            throw XCTSkip("the attached method is only used, and only measured, on macOS 27 and later with its calls present")
        }
    }

    private func attachedEvent(_ payload: DockSwipe.HIDPayload, userData: Int64) throws -> (CGEvent, HIDReader.Event) {
        try skipUnlessAttachedMethod()
        guard let reader = HIDReader() else { throw XCTSkip("this Mac lacks a call that reads an attached IOHIDEvent") }
        let event = try XCTUnwrap(DockSwipe.AttachedEvent.event(for: payload, userData: userData))
        let hid = try XCTUnwrap(reader.read(event, integers: [DockSwipe.HIDPayload.motionField, DockSwipe.HIDPayload.flavorField],
                                            doubles: [DockSwipe.HIDPayload.progressField]))
        return (event, hid)
    }

    /// The one event of a frame is type 30 with our tag, and its attached IOHIDEvent reads
    /// back as the payload: a dock swipe for the Dock, the phase both in its flags and as its
    /// phase, the kind, and the progress to within IOKit's fixed point. A `changed` has no
    /// child. Built only: on a Mac without the calls (macOS 26, CI) this skips.
    func testTheAttachedEventCarriesThePayload() throws {
        let userData: Int64 = 0x52415A45
        let payload = DockSwipe.HIDPayload(DockSwipe.Frame(kind: .horizontal, phase: .changed, progress: -0.123456),
                                           naturalScrolling: true)
        let (event, hid) = try attachedEvent(payload, userData: userData)
        XCTAssertEqual(event.type.rawValue, 30)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), userData, "the tag survives the attach")
        XCTAssertEqual(event.getIntegerValueField(CGEventField(rawValue: 110)!), 0, "no CGEvent fields of the old method")
        XCTAssertEqual(hid.type, 23, "kIOHIDEventTypeDockSwipe")
        XCTAssertEqual(hid.flags, 2 << 24)
        XCTAssertEqual(hid.phase, 2, "changed")
        XCTAssertEqual(hid.integers[DockSwipe.HIDPayload.motionField], 1)
        XCTAssertEqual(hid.integers[DockSwipe.HIDPayload.flavorField], 3, "kIOHIDGestureFlavorDockPrimary")
        XCTAssertEqual(try XCTUnwrap(hid.doubles[DockSwipe.HIDPayload.progressField]), 0.123456, accuracy: 1.0 / 65536)
        XCTAssertEqual(hid.children.count, 0, "no velocity before the end")
    }

    /// An end carries the velocity as a child event of the velocity type, X and Y alike.
    func testAnAttachedEndCarriesTheVelocityAsAChild() throws {
        let payload = DockSwipe.HIDPayload(DockSwipe.Frame(kind: .vertical, phase: .ended, progress: 0.5, velocity: -2.25),
                                           naturalScrolling: false)
        let (_, hid) = try attachedEvent(payload, userData: 0)
        XCTAssertEqual(hid.phase, 4, "ended")
        XCTAssertEqual(hid.integers[DockSwipe.HIDPayload.motionField], 2)
        XCTAssertEqual(try XCTUnwrap(hid.doubles[DockSwipe.HIDPayload.progressField]), 0.5, accuracy: 1.0 / 65536)
        XCTAssertEqual(hid.children.count, 1)
        let velocity = try XCTUnwrap(hid.children.first)
        XCTAssertEqual(velocity.type, 9, "kIOHIDEventTypeVelocity")
        for field in DockSwipe.HIDPayload.velocityFields {
            XCTAssertEqual(try XCTUnwrap(velocity.doubles[field]), -2.25, accuracy: 1.0 / 65536)
        }
    }

    /// With the attached method a frame is one event, and the poster reads Natural scrolling
    /// once per swipe, as it begins, so a swipe keeps one sign however the setting changes.
    /// The end still goes out again twice. Skips on a Mac without the calls.
    func testThePosterSendsOneAttachedEventAFrameSignedAsTheSwipeBegan() throws {
        try skipUnlessAttachedMethod()
        guard let reader = HIDReader() else { throw XCTSkip("this Mac lacks a call that reads an attached IOHIDEvent") }
        let sent = Sent()
        var natural = true, asked = 0
        let poster = DockSwipePoster(userData: 7, method: .attachedHIDEvent,
                                     naturalScrolling: { asked += 1; return natural },
                                     send: { sent.events.append($0) })
        func progress(_ event: CGEvent?) -> Double? {
            event.flatMap { reader.read($0, integers: [], doubles: [DockSwipe.HIDPayload.progressField]) }?
                .doubles[DockSwipe.HIDPayload.progressField]
        }

        poster.post(DockSwipe.Frame(kind: .horizontal, phase: .began, progress: 0.25))
        natural = false
        poster.post(DockSwipe.Frame(kind: .horizontal, phase: .changed, progress: 0.5))
        XCTAssertEqual(sent.events.map(\.type.rawValue), [30, 30], "one event a frame, no type 29")
        XCTAssertEqual(asked, 1, "asked as the swipe began, not at every frame")
        XCTAssertEqual(try XCTUnwrap(progress(sent.events.last)), -0.5, accuracy: 1.0 / 65536,
                       "still the sign the swipe began with")
        XCTAssertEqual(sent.events.map { $0.getIntegerValueField(.eventSourceUserData) }, [7, 7])

        poster.post(DockSwipe.Frame(kind: .horizontal, phase: .ended, progress: 0.5, velocity: 1))
        XCTAssertEqual(sent.events.count, 3)
        XCTAssertEqual(poster.repeatTimers.count, DockSwipePoster.endRepeats.count)
        poster.repeatTimers[0].fire()
        XCTAssertEqual(sent.events.count, 4, "the end again")
        XCTAssertTrue(sent.events[3] === sent.events[2], "the same event, attached once")

        poster.post(DockSwipe.Frame(kind: .horizontal, phase: .began, progress: 0.25))
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(try XCTUnwrap(progress(sent.events.last)), 0.25, accuracy: 1.0 / 65536,
                       "the next swipe reads the setting again: now off, sign kept")
        XCTAssertEqual(poster.repeatTimers, [], "its start stopped the end's repeats")
    }

    /// macOS 26 and earlier keep the fields method as it was: its poster never asks for
    /// Natural scrolling, a preferences read at every swipe that it has no use for, and its
    /// events carry the tracker's progress and velocity whatever the setting says.
    func testTheFieldsMethodNeverAsksForNaturalScrolling() {
        let sent = Sent()
        var asked = 0
        let poster = DockSwipePoster(userData: 7, method: .eventFields,
                                     naturalScrolling: { asked += 1; return true },
                                     send: { sent.events.append($0) })
        poster.post(DockSwipe.Frame(kind: .horizontal, phase: .began, progress: -0.25))
        poster.post(DockSwipe.Frame(kind: .horizontal, phase: .changed, progress: -0.5))
        poster.post(DockSwipe.Frame(kind: .horizontal, phase: .ended, progress: -0.5, velocity: -1))
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(sent.events.map(\.type.rawValue), [30, 29, 30, 29, 30, 29])
        XCTAssertEqual(sent.events[2].getDoubleValueField(field(124)), -0.5, "not flipped")
        XCTAssertEqual(sent.events[4].getDoubleValueField(field(129)), -1, "nor the velocity")
    }

    /// While Natural scrolling is on, an attached end flips its velocity child together with
    /// its progress: flipped apart, they disagree and the Dock rebounds as the swipe lets go.
    /// Read back from the event itself, not only the payload. Skips on a Mac without the calls.
    func testAnAttachedEndFlipsItsVelocityWithItsProgress() throws {
        let frame = DockSwipe.Frame(kind: .horizontal, phase: .ended, progress: -0.75, velocity: -1.5)
        let (_, hid) = try attachedEvent(DockSwipe.HIDPayload(frame, naturalScrolling: true), userData: 0)
        XCTAssertEqual(hid.phase, 4, "ended")
        XCTAssertEqual(hid.integers[DockSwipe.HIDPayload.motionField], 1, "horizontal")
        XCTAssertEqual(try XCTUnwrap(hid.doubles[DockSwipe.HIDPayload.progressField]), 0.75, accuracy: 1.0 / 65536)
        let velocity = try XCTUnwrap(hid.children.first)
        for field in DockSwipe.HIDPayload.velocityFields {
            XCTAssertEqual(try XCTUnwrap(velocity.doubles[field]), 1.5, accuracy: 1.0 / 65536, "flipped with it")
        }
    }

    /// Every reset of a hold cancels its swipe (`ButtonRemapper.gestureHold`), with no velocity
    /// of its own. With the attached method that cancel keeps the sign the swipe began with,
    /// whatever Natural scrolling says by then, so the Dock snaps back the way it came, and it
    /// goes out again like any end. Skips on a Mac without the calls.
    func testAnAttachedCancelKeepsTheSignTheSwipeBeganWith() throws {
        try skipUnlessAttachedMethod()
        guard let reader = HIDReader() else { throw XCTSkip("this Mac lacks a call that reads an attached IOHIDEvent") }
        let sent = Sent()
        var natural = true
        let poster = DockSwipePoster(userData: 7, method: .attachedHIDEvent, naturalScrolling: { natural },
                                     send: { sent.events.append($0) })
        poster.post(DockSwipe.Frame(kind: .vertical, phase: .began, progress: -0.2))
        natural = false
        poster.post(DockSwipe.Frame(kind: .vertical, phase: .cancelled, progress: -0.3))
        let cancel = try XCTUnwrap(reader.read(try XCTUnwrap(sent.events.last), integers: [DockSwipe.HIDPayload.motionField],
                                               doubles: [DockSwipe.HIDPayload.progressField]))
        XCTAssertEqual(cancel.phase, 8, "cancelled")
        XCTAssertEqual(cancel.integers[DockSwipe.HIDPayload.motionField], 2, "vertical")
        XCTAssertEqual(try XCTUnwrap(cancel.doubles[DockSwipe.HIDPayload.progressField]), 0.3, accuracy: 1.0 / 65536,
                       "flipped, as the swipe began with Natural scrolling on")
        XCTAssertEqual(cancel.children.count, 1)
        XCTAssertEqual(cancel.children.first?.doubles[DockSwipe.HIDPayload.velocityFields[0]], 0, "no speed to go on")
        XCTAssertEqual(poster.repeatTimers.count, DockSwipePoster.endRepeats.count)
    }

    /// The attached method makes an IOHIDEvent every frame, and a second one at the end, at up
    /// to 240 frames a second while a button is held: one that isn't released (about 150 bytes
    /// each) piles up for as long as the app runs, and one released once too often crashes it.
    /// Built and dropped many times, the heap stays where it was, so the CGEvent alone owns what
    /// it carries. Nothing is posted. Skips on a Mac without the calls.
    func testAttachedEventsLeaveNothingBehind() throws {
        try skipUnlessAttachedMethod()
        func heapInUse() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return stats.size_in_use
        }
        let count = 20_000
        let payloads = [
            DockSwipe.HIDPayload(DockSwipe.Frame(kind: .horizontal, phase: .changed, progress: 0.3), naturalScrolling: true),
            DockSwipe.HIDPayload(DockSwipe.Frame(kind: .vertical, phase: .ended, progress: 0.3, velocity: 1.5),
                                 naturalScrolling: true),
        ]
        for payload in payloads {
            XCTAssertNotNil(DockSwipe.AttachedEvent.event(for: payload, userData: 7), "events are made at all")
            for _ in 0..<1000 { autoreleasepool { _ = DockSwipe.AttachedEvent.event(for: payload, userData: 7) } }
            let before = heapInUse()
            for _ in 0..<count { autoreleasepool { _ = DockSwipe.AttachedEvent.event(for: payload, userData: 7) } }
            let grown = heapInUse() - before
            XCTAssertLessThan(grown, count * 16, "\(grown) bytes for \(count) events, phase \(payload.flags >> 24)")
        }
    }
}

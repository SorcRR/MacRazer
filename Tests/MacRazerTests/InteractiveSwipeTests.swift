// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import XCTest
@testable import MacRazer

/// A gesture whose slots hold the system swipes, through the tap: Mission Control, App
/// Exposé and the Spaces follow the pointer as a dock swipe while the hold lasts, and every
/// other slot keeps firing once. Synthetic events into `handle`; the actions land in
/// `actionEmitter` and the swipe's frames in a recorder (`DockSwipeOutput`), with time from a
/// clock the test moves, so nothing needs Accessibility, reaches the session or waits.
final class InteractiveSwipeTests: XCTestCase {
    private let back = 3
    /// 1 point is 0.001 of progress sideways and 0.002 up or down.
    private let scale = DockSwipe.Scale(horizontal: 0.001, vertical: 0.002)
    private let playPause = RemapAction.mediaKey(code: 16, name: "Play / Pause")
    private let copy = RemapAction.keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy  ⌘C")

    private func preset(_ id: String) -> RemapAction { ButtonRemapper.presets.first { $0.id == id }!.action }

    /// All four system swipes, each on its own side (Mission Control up, App Exposé down, Space
    /// Left left, Space Right right), with Play / Pause as the click, so a click shows up.
    private var bindings: GestureBindings {
        GestureBindings(click: playPause, up: preset("missionControl"), down: preset("appExpose"),
                        left: preset("spaceLeft"), right: preset("spaceRight"))
    }

    private final class Recorded {
        var actions: [RemapAction] = []
        var frames: [DockSwipe.Frame] = []
        var phases: [DockSwipe.Phase] { frames.map(\.phase) }
    }

    private final class Clock {
        var now: TimeInterval = 1000
    }

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "MacRazerTests.InteractiveSwipe.\(name)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// The Dock's App Exposé trackpad gesture, as the remapper reads it at each hold.
    private final class DockSetting {
        var appExpose = true
        var reads = 0
    }

    private func output(_ recorded: Recorded, dock: DockSetting = DockSetting()) -> DockSwipeOutput {
        let scale = scale
        return DockSwipeOutput(send: { recorded.frames.append($0) }, scale: { scale },
                               appExposeEnabled: { dock.reads += 1; return dock.appExpose })
    }

    /// A remapper with Back as a gesture of `bindings` (all four swipes unless given).
    private func remapper(_ recorded: Recorded, bindings: GestureBindings? = nil, clock: Clock = Clock(),
                          dock: DockSetting = DockSetting(), name: String = #function) -> ButtonRemapper {
        let r = ButtonRemapper(defaults: defaults(name), actionEmitter: { recorded.actions.append($0) },
                               dockSwipes: output(recorded, dock: dock), clock: { clock.now })
        r.setMappings([back: .gesture(bindings ?? self.bindings)])
        return r
    }

    /// Whether the tap let the event through, answered while `event` is still alive.
    @discardableResult
    private func send(_ r: ButtonRemapper, _ type: CGEventType, button: Int? = nil,
                      dx: Int64 = 0, dy: Int64 = 0) -> Bool {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                            mouseButton: CGMouseButton(rawValue: UInt32(button ?? back))!)!
        event.setIntegerValueField(.mouseEventDeltaX, value: dx)
        event.setIntegerValueField(.mouseEventDeltaY, value: dy)
        return r.handle(type: type, event: event) != nil
    }

    /// A drag of the held button, 10 ms after the last event.
    @discardableResult
    private func drag(_ r: ButtonRemapper, _ clock: Clock, dx: Int64 = 0, dy: Int64 = 0) -> Bool {
        clock.now += 0.01
        return send(r, .otherMouseDragged, dx: dx, dy: dy)
    }

    // MARK: A mouse button's hold

    /// Holding the button and moving left drags the desktop towards the previous Space: one
    /// `began` as the hold leaves the dead zone, a `changed` for each movement after it with
    /// the total so far, and the release ends it with the hand's velocity, for the Dock to
    /// finish or snap back. No shortcut is typed, and apps see none of it.
    func testAHoldDragsTheSwipeAndTheReleaseEndsIt() throws {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock)
        XCTAssertFalse(send(r, .otherMouseDown))
        XCTAssertFalse(drag(r, clock, dx: -8), "swallowed while held, as before")
        XCTAssertEqual(recorded.frames, [], "inside the dead zone")
        drag(r, clock, dx: -8)
        XCTAssertEqual(recorded.phases, [.began])
        XCTAssertEqual(recorded.frames.first?.kind, .horizontal)
        for _ in 0..<3 { drag(r, clock, dx: -20) }
        XCTAssertEqual(recorded.phases, [.began, .changed, .changed, .changed])
        let progress = recorded.frames.map(\.progress)
        for (got, expected) in zip(progress, [-0.016, -0.036, -0.056, -0.076]) {
            XCTAssertEqual(got, expected, accuracy: 1e-9)
        }
        XCTAssertFalse(drag(r, clock, dy: -40), "the other axis is the swipe's too, and swallowed")
        XCTAssertEqual(recorded.frames.count, 4, "but moves nothing")

        XCTAssertFalse(send(r, .otherMouseUp))
        let end = try XCTUnwrap(recorded.frames.last)
        XCTAssertEqual(end.phase, .ended)
        XCTAssertEqual(end.progress, -0.076, accuracy: 1e-9)
        XCTAssertLessThan(end.velocity, 0, "still moving left")
        XCTAssertEqual(recorded.phases.filter { $0 == .began }.count, 1)
        XCTAssertEqual(recorded.actions, [], "no Space Left shortcut, and no click")
        XCTAssertNil(r.gestureHold)
        XCTAssertTrue(drag(r, clock, dx: -20), "no hold to feed")
        XCTAssertEqual(recorded.frames.count, 5)
    }

    /// Each direction heads for its slot: up opens Mission Control (negative), down App
    /// Exposé, right the next Space.
    func testEachDirectionHeadsForItsSlot() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock)
        for (dx, dy) in [(Int64(0), Int64(-30)), (0, 30), (30, 0)] {
            send(r, .otherMouseDown)
            drag(r, clock, dx: dx, dy: dy)
            send(r, .otherMouseUp)
        }
        let began = recorded.frames.filter { $0.phase == .began }
        XCTAssertEqual(began.map(\.kind), [.vertical, .vertical, .horizontal])
        XCTAssertEqual(began.map { $0.progress < 0 }, [true, false, false])
        XCTAssertEqual(recorded.actions, [])
    }

    /// The click still fires for a press and release inside the dead zone, and nothing is
    /// sent to the Dock.
    func testAPressInsideTheDeadZoneIsStillTheClick() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock)
        send(r, .otherMouseDown)
        drag(r, clock, dx: 12, dy: 8)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.actions, [playPause])
        XCTAssertEqual(recorded.frames, [])
    }

    /// Out and back to the start is no longer a click once the swipe began: it snaps back
    /// (cancelled), as a trackpad's swipe taken back does.
    func testASwipeTakenBackIsCancelledAndNoClick() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock)
        send(r, .otherMouseDown)
        drag(r, clock, dx: 40)
        drag(r, clock, dx: -40)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.phases, [.began, .changed, .cancelled])
        XCTAssertEqual(recorded.frames.last?.progress, 0)
        XCTAssertEqual(recorded.actions, [])
    }

    /// A slot that isn't a system swipe keeps the discrete swipe: it fires once at 50 points,
    /// and no dock swipe begins, even across the opposite slot that is one.
    func testAnotherActionStillFiresOnce() {
        let recorded = Recorded()
        let clock = Clock()
        var mixed = bindings
        mixed.up = copy
        let r = remapper(recorded, bindings: mixed, clock: clock)
        send(r, .otherMouseDown)
        drag(r, clock, dy: -30)
        XCTAssertEqual(recorded.actions, [])
        drag(r, clock, dy: -30)
        XCTAssertEqual(recorded.actions, [copy], "fired during the movement")
        drag(r, clock, dy: 200)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.actions, [copy], "once, and not App Exposé after it")
        XCTAssertEqual(recorded.frames, [])

        // The same hold going left is the Space swipe.
        send(r, .otherMouseDown)
        drag(r, clock, dx: -30)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.phases, [.began, .ended])
        XCTAssertEqual(recorded.actions, [copy])
    }

    /// With nowhere for dock swipes to go (a macOS that ignores them), the presets are the
    /// keyboard shortcuts they always were.
    func testWithoutDockSwipesThePresetsStayShortcuts() {
        let recorded = Recorded()
        let r = ButtonRemapper(defaults: defaults(#function), actionEmitter: { recorded.actions.append($0) })
        r.setMappings([back: .gesture(bindings)])
        send(r, .otherMouseDown)
        send(r, .otherMouseDragged, dy: -60)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.actions, [bindings.up])
        XCTAssertNil(r.gestureHold)
    }

    /// The ways a hold ends early. Each must cancel the open swipe, so the Dock is never
    /// left halfway between two Spaces.
    private var earlyEndings: [(String, (ButtonRemapper) -> Void)] {
        [
            ("paused", { $0.remappingPaused = true }),
            ("tap disabled", { _ = $0.handle(type: .tapDisabledByTimeout, event: CGEvent(source: nil)!) }),
            ("device change", { $0.setActiveDevice("OTHER-MOUSE") }),
            ("action changed", { $0.setAction(.passthrough, for: 3) }),
            ("slot changed", { $0.setGestureAction(.doubleClick, for: .left, of: 3) }),
            ("profile", { $0.setMappings([:]) }),
            ("another button", { r in
                let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                                    mouseButton: .center)!
                _ = r.handle(type: .otherMouseDown, event: event)
            }),
            ("wake", { $0.cancelGesture() }),
        ]
    }

    /// Every reset of a hold cancels its swipe, once, with the progress it had; the release
    /// after it sends nothing more and fires nothing.
    func testEveryEarlyEndingCancelsTheSwipe() {
        for (name, end) in earlyEndings {
            let recorded = Recorded()
            let clock = Clock()
            let r = remapper(recorded, clock: clock, name: "\(#function)-\(name)")
            send(r, .otherMouseDown)
            drag(r, clock, dx: 30)
            drag(r, clock, dx: 10)
            end(r)
            XCTAssertNil(r.gestureHold, name)
            XCTAssertEqual(recorded.phases, [.began, .changed, .cancelled], name)
            XCTAssertEqual(recorded.frames.last?.progress ?? 0, 0.04, accuracy: 1e-9, name)
            XCTAssertEqual(recorded.frames.last?.velocity, 0, name)
            XCTAssertFalse(send(r, .otherMouseUp), "\(name): the release of a swallowed press")
            drag(r, clock, dx: 30)
            XCTAssertEqual(recorded.frames.count, 3, "\(name): nothing after the cancel")
            XCTAssertEqual(recorded.actions, [], "\(name): no click")
        }
    }

    /// A reset before the swipe began has nothing to cancel.
    func testAResetInsideTheDeadZoneSendsNothing() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock)
        send(r, .otherMouseDown)
        drag(r, clock, dx: 5)
        r.cancelGesture()
        XCTAssertEqual(recorded.frames, [])
    }

    // MARK: App Exposé, and the default gesture

    /// App Exposé follows the pointer only while the Dock's trackpad gesture for it is on. Off,
    /// as it is out of the box, the Dock would ignore the swipe, so the slot is its ⌃↓ shortcut,
    /// fired once at 50 points, and nothing goes to the Dock. The setting is read at each hold,
    /// so turning it on counts from the next press.
    func testAppExposeIsASwipeOnlyWhileItsTrackpadGestureIsOn() {
        let recorded = Recorded()
        let clock = Clock()
        let dock = DockSetting()
        dock.appExpose = false
        let r = remapper(recorded, clock: clock, dock: dock)
        send(r, .otherMouseDown)
        drag(r, clock, dy: 30)
        XCTAssertEqual(recorded.actions, [], "not yet 50 points")
        drag(r, clock, dy: 30)
        drag(r, clock, dy: 200)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.actions, [preset("appExpose")], "the shortcut, once")
        XCTAssertEqual(recorded.frames, [], "nothing for the Dock")
        XCTAssertEqual(dock.reads, 1, "read as the hold began")

        // The other swipes still follow the pointer with it off.
        send(r, .otherMouseDown)
        drag(r, clock, dy: -30)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.phases.first, .began)
        XCTAssertEqual(recorded.frames.first?.kind, .vertical)
        XCTAssertLessThan(recorded.frames.first?.progress ?? 0, 0, "Mission Control")

        dock.appExpose = true
        recorded.frames = []
        send(r, .otherMouseDown)
        drag(r, clock, dy: 30)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.phases.first, .began, "on now: App Exposé follows the pointer")
        XCTAssertGreaterThan(recorded.frames.first?.progress ?? 0, 0)
        XCTAssertEqual(recorded.actions, [preset("appExpose")], "and no shortcut this time")
        XCTAssertEqual(dock.reads, 3)
    }

    /// With App Exposé off and Mission Control up, a swipe up taken back down stops at the start:
    /// the shortcut below it never takes over a swipe under way.
    func testAppExposeOffNeverTakesOverMissionControl() {
        let recorded = Recorded()
        let clock = Clock()
        let dock = DockSetting()
        dock.appExpose = false
        let r = remapper(recorded, clock: clock, dock: dock)
        send(r, .otherMouseDown)
        drag(r, clock, dy: -30)
        drag(r, clock, dy: 200)
        XCTAssertEqual(recorded.frames.last?.progress, 0, "clamped at the start")
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.phases.last, .cancelled)
        XCTAssertEqual(recorded.actions, [])
    }

    /// The default gesture mixes the axis: Mission Control up follows the pointer, Launchpad
    /// down is an ordinary action. Moving down fires Launchpad once at 50 points and sends the
    /// Dock nothing; moving up drives Mission Control, and taking it back down past the start
    /// stops there, as Launchpad isn't the same swipe the other way: it never fires then, and
    /// Mission Control is never driven backwards.
    func testTheDefaultsMixASwipeUpAndLaunchpadDown() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, bindings: .defaults(click: playPause), clock: clock)
        send(r, .otherMouseDown)
        drag(r, clock, dy: 30)
        XCTAssertEqual(recorded.actions, [])
        drag(r, clock, dy: 30)
        XCTAssertEqual(recorded.actions, [.launchpad], "at 50 points")
        drag(r, clock, dy: 300)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.actions, [.launchpad], "once")
        XCTAssertEqual(recorded.frames, [], "no swipe for the Dock")

        send(r, .otherMouseDown)
        drag(r, clock, dy: -30)
        XCTAssertEqual(recorded.phases, [.began])
        XCTAssertLessThan(recorded.frames[0].progress, 0, "towards Mission Control")
        drag(r, clock, dy: 300)
        XCTAssertTrue(recorded.frames.allSatisfy { $0.progress <= 0 }, "never past the start")
        XCTAssertEqual(recorded.frames.last?.progress, 0)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.phases.last, .cancelled)
        XCTAssertEqual(recorded.actions, [.launchpad], "no Launchpad from a swipe taken back")
    }

    /// The default Spaces move the way a trackpad drags the desktop: the pointer moving right
    /// drives the swipe towards the previous Space (Space Left, negative progress), so the
    /// desktop follows the hand, and moving left brings the next Space.
    func testTheDefaultSpacesFollowTheHand() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, bindings: .defaults(click: playPause), clock: clock)
        send(r, .otherMouseDown)
        drag(r, clock, dx: 30)
        drag(r, clock, dx: 20)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.frames.first?.kind, .horizontal)
        XCTAssertEqual(recorded.frames.first?.progress ?? 0, -0.03, accuracy: 1e-9, "towards the previous Space")
        XCTAssertEqual(recorded.phases.last, .ended)
        XCTAssertLessThan(recorded.frames.last?.velocity ?? 0, 0)

        recorded.frames = []
        send(r, .otherMouseDown)
        drag(r, clock, dx: -30)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.frames.first?.progress ?? 0, 0.03, accuracy: 1e-9, "towards the next Space")
        XCTAssertEqual(recorded.actions, [])
    }

    /// The editor says the four follow the pointer, where they do.
    func testTheEditorSaysTheSystemSwipesFollowThePointer() {
        let text = RemapView.gestureEditorExplanation(followsPointer: true)
        XCTAssertTrue(text.contains("Mission Control and the Spaces follow the pointer while you hold it, and so does App Exposé with its trackpad gesture on."))
        XCTAssertFalse(text.contains("\u{2014}"), "no em dash")
        XCTAssertFalse(RemapView.gestureEditorExplanation(followsPointer: false).contains("follow the pointer"),
                       "not where they stay shortcuts")
    }
}

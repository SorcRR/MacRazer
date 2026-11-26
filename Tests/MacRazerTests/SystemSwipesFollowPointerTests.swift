// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import XCTest
@testable import MacRazer

/// The setting that turns the progressive transitions off (`ButtonRemapper.systemSwipesFollowPointer`).
/// On, Mission Control, App Exposé and the Spaces follow the pointer as a dock swipe; off, each
/// is the keyboard shortcut its slot holds, fired once at 50 points like every other action,
/// exactly as on a Mac without dock swipes. Synthetic events into `handle`, the actions caught
/// by `actionEmitter`, the swipe's frames by a recorder (`DockSwipeOutput`) and time from a
/// clock the test moves, as in `InteractiveSwipeTests`, so nothing needs Accessibility,
/// reaches the session or waits.
final class SystemSwipesFollowPointerTests: XCTestCase {
    private let back = 3
    /// 1 point is 0.001 of progress sideways and 0.002 up or down.
    private let scale = DockSwipe.Scale(horizontal: 0.001, vertical: 0.002)
    private let playPause = RemapAction.mediaKey(code: 16, name: "Play / Pause")

    private func preset(_ id: String) -> RemapAction { ButtonRemapper.presets.first { $0.id == id }!.action }

    /// All four system swipes, each on its own side, with Play / Pause as the click, so a click
    /// shows up.
    private var bindings: GestureBindings {
        GestureBindings(click: playPause, up: preset("missionControl"), down: preset("appExpose"),
                        left: preset("spaceLeft"), right: preset("spaceRight"))
    }

    /// Each system swipe of `bindings`: the way one point of the pointer goes for it, and the
    /// preset its slot holds.
    private var swipes: [(name: String, dx: Int64, dy: Int64, action: RemapAction)] {
        [("Mission Control", 0, -1, preset("missionControl")), ("App Exposé", 0, 1, preset("appExpose")),
         ("Space Left", -1, 0, preset("spaceLeft")), ("Space Right", 1, 0, preset("spaceRight"))]
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

    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "MacRazerTests.SystemSwipesFollowPointer.\(name)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Where the swipes go: the recorder, with the Dock's App Exposé gesture on, so App Exposé
    /// is a shortcut only because of the setting.
    private func output(_ recorded: Recorded) -> DockSwipeOutput {
        let scale = scale
        return DockSwipeOutput(send: { recorded.frames.append($0) }, scale: { scale }, appExposeEnabled: { true })
    }

    /// A remapper with Back as a gesture of `bindings`, on `defaults`.
    private func remapper(_ recorded: Recorded, clock: Clock, defaults: UserDefaults) -> ButtonRemapper {
        let r = ButtonRemapper(defaults: defaults, actionEmitter: { recorded.actions.append($0) },
                               dockSwipes: output(recorded), clock: { clock.now })
        r.setMappings([back: .gesture(bindings)])
        return r
    }

    /// Whether the tap let the event through, answered while `event` is still alive.
    @discardableResult
    private func send(_ r: ButtonRemapper, _ type: CGEventType, dx: Int64 = 0, dy: Int64 = 0) -> Bool {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                            mouseButton: CGMouseButton(rawValue: UInt32(back))!)!
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

    // MARK: The default

    /// The progressive transitions are what these gestures are built around, so a Mac that
    /// never touched the setting has them: on, nothing written until it is changed, and a
    /// hold that heads for Mission Control drives a dock swipe rather than typing ⌃↑.
    func testTheSystemSwipesFollowThePointerOutOfTheBox() {
        let recorded = Recorded()
        let clock = Clock()
        let store = defaults()
        let r = remapper(recorded, clock: clock, defaults: store)
        XCTAssertTrue(r.systemSwipesFollowPointer)
        XCTAssertTrue(r.systemSwipesFollowPointerHere)
        XCTAssertNil(store.object(forKey: ButtonRemapper.systemSwipesFollowPointerKey), "not written until changed")
        send(r, .otherMouseDown)
        drag(r, clock, dy: -30)
        drag(r, clock, dy: -30)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.phases.first, .began)
        XCTAssertEqual(recorded.phases.last, .ended)
        XCTAssertEqual(recorded.actions, [], "no shortcut")
    }

    // MARK: Off: shortcuts fired once

    /// Off, a hold is what it is on a Mac without dock swipes: no tracker, and each preset is
    /// its keyboard shortcut, fired once as the movement reaches 50 points, never again for the
    /// rest of the hold, and no frame for the Dock. App Exposé too, with its trackpad gesture
    /// on.
    func testOffEachPresetFiresItsShortcutOnceAt50Points() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock, defaults: defaults())
        r.systemSwipesFollowPointer = false
        XCTAssertFalse(r.systemSwipesFollowPointerHere)
        for swipe in swipes {
            recorded.actions = []
            XCTAssertFalse(send(r, .otherMouseDown), swipe.name)
            XCTAssertNotNil(r.gestureHold, swipe.name)
            XCTAssertNil(r.gestureHold?.swipe, "\(swipe.name): no tracker")
            XCTAssertFalse(drag(r, clock, dx: swipe.dx * 49, dy: swipe.dy * 49), "\(swipe.name): swallowed while held")
            XCTAssertEqual(recorded.actions, [], "\(swipe.name): 49 points")
            drag(r, clock, dx: swipe.dx, dy: swipe.dy)
            XCTAssertEqual(recorded.actions, [swipe.action], "\(swipe.name): at 50 points")
            drag(r, clock, dx: swipe.dx * 300, dy: swipe.dy * 300)
            drag(r, clock, dx: -swipe.dx * 600, dy: -swipe.dy * 600)
            XCTAssertFalse(send(r, .otherMouseUp), swipe.name)
            XCTAssertEqual(recorded.actions, [swipe.action], "\(swipe.name): once, and no click")
            XCTAssertNil(r.gestureHold, swipe.name)
        }
        XCTAssertEqual(recorded.frames, [], "nothing for the Dock")
    }

    // MARK: Changed during a hold

    /// Turned off with a swipe open, the hold ends and its swipe is cancelled once with the
    /// progress it had, so the Dock snaps back instead of staying halfway between two Spaces.
    /// The release after it is still swallowed and fires nothing, and the next hold types
    /// the shortcut.
    func testTurningItOffMidSwipeCancelsTheSwipe() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock, defaults: defaults())
        send(r, .otherMouseDown)
        drag(r, clock, dx: 30)
        drag(r, clock, dx: 10)
        XCTAssertEqual(recorded.phases, [.began, .changed])
        r.systemSwipesFollowPointer = false
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(recorded.phases, [.began, .changed, .cancelled])
        XCTAssertEqual(recorded.frames.last?.progress ?? 0, 0.04, accuracy: 1e-9)
        XCTAssertFalse(send(r, .otherMouseUp), "the release of a swallowed press")
        XCTAssertTrue(drag(r, clock, dx: 30), "no hold to feed")
        XCTAssertEqual(recorded.frames.count, 3, "nothing after the cancel")
        XCTAssertEqual(recorded.actions, [], "no click, no shortcut")

        send(r, .otherMouseDown)
        drag(r, clock, dx: 60)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.actions, [preset("spaceRight")])
        XCTAssertEqual(recorded.frames.count, 3)
    }

    /// Turned back on during a hold that has no tracker, the hold ends too, without firing:
    /// a hold never goes on the other way from how it began, and its release is no click.
    /// Writing the value it already has (as a view may) leaves the hold alone.
    func testChangingItMidHoldEndsTheHoldWithoutFiring() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock, defaults: defaults())
        r.systemSwipesFollowPointer = false
        send(r, .otherMouseDown)
        drag(r, clock, dy: -30)
        r.systemSwipesFollowPointer = false
        XCTAssertNotNil(r.gestureHold, "unchanged: the hold goes on")
        r.systemSwipesFollowPointer = true
        XCTAssertNil(r.gestureHold)
        XCTAssertFalse(send(r, .otherMouseUp), "the release of a swallowed press")
        XCTAssertEqual(recorded.actions, [], "no shortcut and no click")
        XCTAssertEqual(recorded.frames, [])
    }

    // MARK: Saved

    /// One setting for the app: saved as it changes, read back by every remapper on the same
    /// defaults, as the app's is on its next launch, and kept across a change of mouse and a
    /// profile, which carry only mappings.
    func testTheSettingIsSavedForTheAppNotPerDeviceOrProfile() {
        let recorded = Recorded()
        let clock = Clock()
        let store = defaults()
        let first = remapper(recorded, clock: clock, defaults: store)
        first.systemSwipesFollowPointer = false
        XCTAssertEqual(store.object(forKey: ButtonRemapper.systemSwipesFollowPointerKey) as? Bool, false)

        let second = remapper(recorded, clock: clock, defaults: store)
        XCTAssertFalse(second.systemSwipesFollowPointer)
        send(second, .otherMouseDown)
        drag(second, clock, dy: -60)
        send(second, .otherMouseUp)
        XCTAssertEqual(recorded.actions, [preset("missionControl")], "a shortcut on the new one too")
        XCTAssertEqual(recorded.frames, [])

        second.setActiveDevice("ANOTHER-MOUSE")
        second.setMappings([back: .gesture(bindings)])
        XCTAssertFalse(second.systemSwipesFollowPointer, "not the mouse's, nor the profile's")
        second.systemSwipesFollowPointer = true
        XCTAssertEqual(store.object(forKey: ButtonRemapper.systemSwipesFollowPointerKey) as? Bool, true)
        XCTAssertTrue(remapper(recorded, clock: clock, defaults: store).systemSwipesFollowPointer)
    }

    // MARK: The editor's text

    /// The gesture editor's explanation says the four follow the pointer only while they do:
    /// with the setting on, where dock swipes go somewhere. Off, or on a Mac without them, it
    /// leaves that sentence out, as the four are then shortcuts like the rest. The checkbox's
    /// label is a plain sentence.
    func testTheEditorTextFollowsTheSetting() {
        let recorded = Recorded()
        let r = remapper(recorded, clock: Clock(), defaults: defaults())
        let sentence = "Mission Control and the Spaces follow the pointer while you hold it"
        r.systemSwipesFollowPointer = true
        XCTAssertTrue(RemapView.gestureEditorExplanation(followsPointer: r.systemSwipesFollowPointerHere)
            .contains(sentence), "on")
        r.systemSwipesFollowPointer = false
        let off = RemapView.gestureEditorExplanation(followsPointer: r.systemSwipesFollowPointerHere)
        XCTAssertFalse(off.contains("follow the pointer"), "off")
        XCTAssertTrue(off.hasPrefix("Hold the button"), off)

        let withoutDockSwipes = ButtonRemapper(defaults: defaults("\(#function)-without"), actionEmitter: { _ in })
        XCTAssertTrue(withoutDockSwipes.systemSwipesFollowPointer)
        XCTAssertFalse(withoutDockSwipes.systemSwipesFollowPointerHere, "nowhere for the swipes to go")

        XCTAssertEqual(RemapView.followPointerToggleTitle, "Mission Control and Spaces follow the pointer")
        XCTAssertFalse(RemapView.followPointerToggleTitle.contains("\u{2014}"), "no em dash")
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import XCTest
@testable import MacRazer

/// Where gestures and Launchpad meet HyperShift, the mouse-only actions and remaps saved in
/// the mouse. Synthetic events into `handle`, with the actions caught by `actionEmitter`.
final class GestureAndHyperShiftTests: XCTestCase {
    private var emitted: [RemapAction] = []
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        emitted = []
        super.tearDown()
    }

    /// `pid` 0x0099 has no onboard table, so the tap does everything.
    private func remapper(_ name: String = #function, pid: Int = 0x0099) -> (ButtonRemapper, UserDefaults) {
        let suite = "MacRazerTests.GestureAndHyperShift.\(name)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let r = ButtonRemapper(defaults: defaults) { [weak self] in self?.emitted.append($0) }
        r.setActiveDevice("MOUSE", deviceID: pid)
        return (r, defaults)
    }

    private let copy = RemapAction.keystroke(keyCode: 8, modifiers: 0, name: "Copy")

    @discardableResult
    private func click(_ r: ButtonRemapper, _ button: Int64, down: Bool) -> Bool {
        let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                            mouseButton: CGMouseButton(rawValue: UInt32(button))!)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return r.handle(type: type, event: event) != nil
    }

    /// The HyperShift key's release lets go of the layer even when the key was remapped while
    /// held: the release follows the press, not what the button does by then.
    func testHyperShiftLetsGoOnItsReleaseEvenIfRemappedWhileHeld() {
        let (r, _) = remapper()
        r.setAction(.hyperShift, for: 4)
        XCTAssertFalse(click(r, 4, down: true))
        XCTAssertTrue(r.hyperShiftHeld)
        r.setAction(copy, for: 4)
        XCTAssertFalse(click(r, 4, down: false), "its press was swallowed, so its release is too")
        XCTAssertFalse(r.hyperShiftHeld)
        XCTAssertEqual(emitted, [], "neither the HyperShift press nor its release fires anything")
    }

    /// A button pressed while HyperShift was held keeps its release swallowed after
    /// HyperShift is let go, and doesn't let go of HyperShift itself.
    func testAShiftedPressKeepsItsReleaseAfterHyperShiftIsLetGo() {
        let (r, _) = remapper()
        r.setAction(.hyperShift, for: 4)
        r.setAction(copy, for: ButtonRemapper.hyperShiftKey(3))
        click(r, 4, down: true)
        XCTAssertFalse(click(r, 3, down: true))
        XCTAssertFalse(click(r, 4, down: false))
        XCTAssertFalse(r.hyperShiftHeld)
        XCTAssertFalse(click(r, 3, down: false), "its press was swallowed under HyperShift")
        XCTAssertEqual(emitted, [copy])
    }

    /// A gesture still works next to HyperShift: its click fires on release, nothing twice.
    func testAGestureClickFiresBesideAHyperShiftKey() {
        let (r, _) = remapper()
        r.setAction(.hyperShift, for: 4)
        r.makeGesture(3)
        XCTAssertNotNil(r.gestureBindings(for: 3))
        XCTAssertFalse(click(r, 3, down: true))
        XCTAssertEqual(emitted, [], "a gesture fires on release, or on a swipe")
        XCTAssertFalse(click(r, 3, down: false))
        XCTAssertEqual(emitted, [ButtonRemapper.originalClick(for: 3)])
    }

    /// Gesture… is for real extra buttons on the standard layer: not the primary buttons, the
    /// DPI button, a hardware control or a HyperShift slot.
    func testOnlyExtraButtonsOnTheStandardLayerCanBeGestures() {
        let (r, _) = remapper()
        XCTAssertTrue(r.canBeGesture(3))
        XCTAssertTrue(r.canBeGesture(5))
        XCTAssertFalse(r.canBeGesture(0))
        XCTAssertFalse(r.canBeGesture(1))
        XCTAssertFalse(r.canBeGesture(-1), "the DPI button arrives as F20, never as a drag")
        XCTAssertFalse(r.canBeGesture(ButtonRemapper.hyperShiftKey(3)))
        r.makeGesture(ButtonRemapper.hyperShiftKey(3))
        XCTAssertNil(r.mappings[ButtonRemapper.hyperShiftKey(3)])
    }

    /// A gesture's slot takes only what the tap can fire: not HyperShift, and not what only
    /// the mouse can do.
    func testAGestureSlotRefusesWhatTheTapCantFire() {
        let (r, _) = remapper()
        r.makeGesture(3)
        let before = r.gestureBindings(for: 3)
        for action: RemapAction in [.hyperShift, .dpiStage(up: true), .disabled, .cycleScrollMode,
                                    .turboClick(button: 0, intervalMs: 100, name: "Left Click")] {
            r.setGestureAction(action, for: .up, of: 3)
            XCTAssertEqual(r.gestureBindings(for: 3), before, "\(action)")
        }
        r.setGestureAction(.launchpad, for: .up, of: 3)
        XCTAssertEqual(r.gestureBindings(for: 3)?.up, .launchpad)
    }

    /// Neither is something the mouse can do itself, so on a mouse that keeps its remaps the
    /// control stays on its factory function and the tap does it.
    func testTheMouseLeavesGesturesAndLaunchpadToTheApp() {
        XCTAssertNil(OnboardButtons.nativeBlock(for: .launchpad))
        XCTAssertNil(OnboardButtons.nativeBlock(for: .gesture(.defaults(for: 3))))
    }

    /// 0.9.0 can't read either, so they are saved with the newer actions, and come back.
    func testGesturesAndLaunchpadAreSavedApartAndComeBack() throws {
        let (r, defaults) = remapper()
        r.setAction(copy, for: 2)
        r.makeGesture(3)
        r.setAction(.launchpad, for: 4)
        let (legacy, extended) = RemapStorage.split(r.mappings)
        XCTAssertEqual(Set(legacy.keys), [2])
        XCTAssertEqual(Set(extended.keys), [3, 4])

        let again = ButtonRemapper(defaults: defaults) { _ in }
        again.setActiveDevice("MOUSE", deviceID: 0x0099)
        XCTAssertEqual(again.mappings, r.mappings)
    }
}

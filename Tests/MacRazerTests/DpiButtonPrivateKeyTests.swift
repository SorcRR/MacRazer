// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import CoreGraphics
import IOKit
import XCTest
@testable import MacRazer

/// The DPI button of a mouse that reports it as private keys in driver mode (the Cobra
/// HyperSpeed over Bluetooth, `RazerDevices.dpiButtonPrivateKeys`): report 4 turned into key
/// events, and what the remapper does with them. The keys go straight to `handlePrivateKey`
/// (or through a fake `PrivateKeySource`), pointer moves into `handle`, and the actions land
/// in `actionEmitter`, so nothing here opens a HID device, needs a permission or reaches the
/// session. Dock swipes for the same hold are in `InteractiveSwipeTests`.
final class DpiButtonPrivateKeyTests: XCTestCase {
    private let cobra = 0x00DC
    private let basilisk = 0x00BA
    private let keys = DpiButtonPrivateKeys.cobraHyperSpeed
    private let bindings = GestureBindings(
        click: .mediaKey(code: 16, name: "Play / Pause"),
        up: .keystroke(keyCode: 126, modifiers: 0, name: "Up"),
        down: .keystroke(keyCode: 125, modifiers: 0, name: "Down"),
        left: .keystroke(keyCode: 123, modifiers: 0, name: "Left"),
        right: .keystroke(keyCode: 124, modifiers: 0, name: "Right"))
    private let mute = RemapAction.mediaKey(code: 7, name: "Mute")
    /// `bindings` with Hold on Mute, so a Hold that fires shows up.
    private var withHold: GestureBindings {
        var holding = bindings
        holding.hold = mute
        return holding
    }
    /// What a DPI gesture saved by an earlier build holds: Mission Control up, App Exposé down,
    /// Space Left left and Space Right right. A saved gesture keeps its choices.
    private func earlierLayout(click: RemapAction) -> GestureBindings {
        func preset(_ id: String) -> RemapAction { ButtonRemapper.presets.first { $0.id == id }!.action }
        return GestureBindings(click: click, up: preset("missionControl"), down: preset("appExpose"),
                               left: preset("spaceLeft"), right: preset("spaceRight"))
    }

    private final class Emitted {
        var actions: [RemapAction] = []
        var dpiCycles = 0
    }

    /// A `PrivateKeySource` that opens nothing: it records starts, stops and open checks, can
    /// refuse to start (and then to pass a check), and hands on keys as the watcher would.
    private final class FakeSource: PrivateKeySource {
        var refuses = false
        private(set) var starts: [Int] = []
        private(set) var stops = 0
        private(set) var checks: [Int] = []
        private(set) var isRunning = false
        private var onEvent: ((PrivateKeyEvent) -> Void)?

        func start(productID: Int, onEvent: @escaping (PrivateKeyEvent) -> Void) -> Bool {
            starts.append(productID)
            guard !refuses else { return false }
            isRunning = true
            self.onEvent = onEvent
            return true
        }

        func stop() {
            stops += 1
            isRunning = false
            onEvent = nil
        }

        func canWatch(productID: Int) -> Bool {
            checks.append(productID)
            return !refuses
        }

        func send(_ code: UInt8, down: Bool) { onEvent?(PrivateKeyEvent(code: code, isDown: down)) }
    }

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "MacRazerTests.DpiButtonPrivateKey.\(name)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A remapper on the Cobra over Bluetooth whose DPI button does `action` (the gesture
    /// unless given), in driver mode unless `engaged` is false, whose actions and DPI cycles
    /// land in `emitted`.
    private func remapper(_ emitted: Emitted, action: RemapAction? = nil, engaged: Bool = true,
                          source: PrivateKeySource? = nil, name: String = #function) -> ButtonRemapper {
        let r = ButtonRemapper(defaults: defaults(name), actionEmitter: { emitted.actions.append($0) },
                               privateKeys: source)
        r.onDpiCycleRequest = { emitted.dpiCycles += 1 }
        r.setActiveDevice("COBRA-BT", deviceID: cobra)
        r.saveDpiSoftwareAction(action ?? .gesture(bindings))
        if engaged { r.dpiDriverModeChanged(.engaged) }
        return r
    }

    private func key(_ r: ButtonRemapper, _ code: UInt8, down: Bool) {
        r.handlePrivateKey(PrivateKeyEvent(code: code, isDown: down))
    }

    /// What the firmware sends for a short press: the short key, and nothing held 55 ms later.
    private func shortPress(_ r: ButtonRemapper) {
        key(r, keys.short, down: true)
        key(r, keys.short, down: false)
    }

    /// The pointer moving with no button down. Whether the tap let it through.
    @discardableResult
    private func move(_ r: ButtonRemapper, dx: Int64 = 0, dy: Int64 = 0) -> Bool {
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero,
                            mouseButton: .left)!
        event.setIntegerValueField(.mouseEventDeltaX, value: dx)
        event.setIntegerValueField(.mouseEventDeltaY, value: dy)
        return r.handle(type: .mouseMoved, event: event) != nil
    }

    // MARK: Report 4

    /// The report as IOKit hands it over on the Cobra, its id twice, and with it once: the
    /// keys after the ids, nothing held for all zeros, and nil for any other report.
    func testTheReportsKeysAreReadWithTheIdOnceOrTwice() {
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: [0x04, 0x04, 0xD2, 0, 0, 0, 0, 0, 0]), [0xD2])
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: [0x04, 0x52, 0, 0, 0, 0, 0, 0]), [0x52])
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: [0x52, 0, 0]), [0x52], "no id at all")
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: [0x04, 0x04, 0, 0, 0, 0, 0, 0, 0]), [])
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: [0x04, 0x04, 0x52, 0xD2, 0, 0, 0, 0, 0]), [0x52, 0xD2])
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: []), [])
        XCTAssertNil(PrivateKeyReport.heldKeys(reportID: 1, bytes: [0x01, 0x00, 0x05, 0x00]), "pointer movement")
        XCTAssertNil(PrivateKeyReport.heldKeys(reportID: 5, bytes: [0x05, 0x05, 0x02, 0x03]))
    }

    /// Each frame arrives twice (two HID devices deliver it), so a frame that holds what the
    /// last held changes nothing; a press is one down and one up.
    func testADuplicateFrameFiresNothing() {
        var tracker = PrivateKeyTracker()
        XCTAssertEqual(tracker.update([0xD2]), [PrivateKeyEvent(code: 0xD2, isDown: true)])
        XCTAssertEqual(tracker.update([0xD2]), [], "the same frame again")
        XCTAssertEqual(tracker.update([]), [PrivateKeyEvent(code: 0xD2, isDown: false)])
        XCTAssertEqual(tracker.update([]), [])
        XCTAssertEqual(tracker.held, [])
    }

    /// Several keys at once each go down and up on their own, releases first and in code
    /// order, so the result never depends on a set's order.
    func testSeveralKeysAreTrackedEachOnItsOwn() {
        var tracker = PrivateKeyTracker()
        XCTAssertEqual(tracker.update([0xD2, 0x52]), [PrivateKeyEvent(code: 0x52, isDown: true),
                                                      PrivateKeyEvent(code: 0xD2, isDown: true)])
        XCTAssertEqual(tracker.update([0xD2]), [PrivateKeyEvent(code: 0x52, isDown: false)])
        XCTAssertEqual(tracker.update([0x30]), [PrivateKeyEvent(code: 0xD2, isDown: false),
                                                PrivateKeyEvent(code: 0x30, isDown: true)])
        XCTAssertEqual(tracker.held, [0x30])
    }

    /// The captures from the mouse, end to end: a long hold and a short press, each frame
    /// delivered twice.
    func testTheCapturedFramesMakeOneDownAndOneUpPerPress() {
        var tracker = PrivateKeyTracker()
        let frames: [[UInt8]] = [
            [0x04, 0x04, 0xD2, 0, 0, 0, 0, 0, 0], [0x04, 0x04, 0xD2, 0, 0, 0, 0, 0, 0],
            [0x04, 0x04, 0, 0, 0, 0, 0, 0, 0], [0x04, 0x04, 0, 0, 0, 0, 0, 0, 0],
            [0x04, 0x04, 0x52, 0, 0, 0, 0, 0, 0], [0x04, 0x04, 0x52, 0, 0, 0, 0, 0, 0],
            [0x04, 0x04, 0, 0, 0, 0, 0, 0, 0], [0x04, 0x04, 0, 0, 0, 0, 0, 0, 0],
        ]
        let events = frames.flatMap { tracker.update(PrivateKeyReport.heldKeys(reportID: 4, bytes: $0)!) }
        XCTAssertEqual(events, [PrivateKeyEvent(code: 0xD2, isDown: true), PrivateKeyEvent(code: 0xD2, isDown: false),
                                PrivateKeyEvent(code: 0x52, isDown: true), PrivateKeyEvent(code: 0x52, isDown: false)])
    }

    /// The two HID devices' copies of a short press don't always alternate: IOKit hands over
    /// all of one device's waiting reports at once, so after the main thread was busy for
    /// longer than the 55 ms pulse one device's press and release come before the other's.
    /// One shared array took that for two presses (two DPI steps, or the click twice); only
    /// the first device to deliver counts now, whatever the order.
    func testOneShortPressIsOnePressWhicheverWayTheTwoDevicesCopiesArrive() {
        let down = Set<UInt8>([keys.short]), none = Set<UInt8>()
        let press = [PrivateKeyEvent(code: keys.short, isDown: true), PrivateKeyEvent(code: keys.short, isDown: false)]
        let orders: [(String, [(Set<UInt8>, Int)])] = [
            ("alternating", [(down, 1), (down, 2), (none, 1), (none, 2)]),
            ("one device's frames, then the other's", [(down, 1), (none, 1), (down, 2), (none, 2)]),
            ("the second device first", [(down, 2), (none, 2), (down, 1), (none, 1)]),
        ]
        for (name, frames) in orders {
            var tracker = PrivateKeyTracker()
            let events = frames.flatMap { tracker.update($0.0, from: $0.1) }
            XCTAssertEqual(events, press, name)
        }

        var tracker = PrivateKeyTracker()
        let twoPresses = [(down, 1), (none, 1), (down, 2), (none, 2), (down, 1), (none, 1), (down, 2), (none, 2)]
        XCTAssertEqual(twoPresses.flatMap { tracker.update($0.0, from: $0.1) }, press + press, "two presses are two")
    }

    /// The device whose frames count goes away while it holds a key (the mouse disconnected
    /// mid-hold): the key comes up, so a hold of the DPI button can't outlive the mouse and
    /// turn the next pointer movement into a swipe. That release is marked as the device's
    /// going, not the button's, so nothing a real release fires (Hold) comes of it. Then the
    /// next device to deliver counts. Another device going away changes nothing.
    func testTheCountedDeviceGoingAwayReleasesWhatItHeld() {
        var tracker = PrivateKeyTracker()
        XCTAssertEqual(tracker.update([keys.long], from: 1), [PrivateKeyEvent(code: keys.long, isDown: true)])
        XCTAssertEqual(tracker.update([keys.long], from: 2), [])
        XCTAssertEqual(tracker.sourceGone(2), [], "not the counted one")
        XCTAssertEqual(tracker.held, [keys.long])
        XCTAssertEqual(tracker.sourceGone(1), [PrivateKeyEvent(code: keys.long, isDown: false, deviceGone: true)])
        XCTAssertNil(tracker.source)
        XCTAssertEqual(tracker.sourceGone(1), [], "once")
        XCTAssertEqual(tracker.update([keys.short], from: 3), [PrivateKeyEvent(code: keys.short, isDown: true)],
                       "the next device to deliver counts")
        XCTAssertEqual(tracker.update([], from: 1), [], "a device that went away and came back doesn't")
    }

    /// The release that comes with a disconnect ends the hold through the remapper as the long
    /// key's own release would: an open dock swipe ends, and no click fires. Nor does Hold,
    /// though the hold never moved: the button wasn't let go, the mouse went away.
    func testAReleaseFromADisconnectEndsTheHoldWithoutFiringHold() {
        let emitted = Emitted()
        let r = remapper(emitted, action: .gesture(withHold))
        var tracker = PrivateKeyTracker()
        tracker.update([keys.long], from: 7).forEach(r.handlePrivateKey)
        XCTAssertEqual(r.gestureHold?.trigger, ButtonRemapper.dpiButton)
        tracker.sourceGone(7).forEach(r.handlePrivateKey)
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(emitted.actions, [], "no Hold for a disconnect")
        XCTAssertTrue(move(r, dy: -200))
        XCTAssertEqual(emitted.actions, [], "the pointer moved by anything else after that is no swipe")
    }

    // MARK: Which mice

    /// Only the Cobra over Bluetooth was seen reporting the keys and taking driver mode: the
    /// Basilisk keeps F20, and any mouse not in the list has neither.
    func testOnlyTheCobraOverBluetoothHasPrivateKeys() {
        XCTAssertEqual(RazerDevices.dpiButtonPrivateKeys(pid: cobra), DpiButtonPrivateKeys(short: 0x52, long: 0xD2))
        XCTAssertNil(RazerDevices.dpiButtonPrivateKeys(pid: basilisk))
        XCTAssertNil(RazerDevices.dpiButtonPrivateKeys(pid: 0x00DB), "its dongle")
        XCTAssertNil(RazerDevices.dpiButtonPrivateKeys(pid: 0x00DA), "its cable")
        XCTAssertNil(RazerDevices.dpiButtonPrivateKeys(pid: 0x9999), "unknown")
        for row in RazerDevices.known where row.dpiButtonPrivateKeys != nil {
            XCTAssertEqual(row.connection, .bluetooth, row.name)
            XCTAssertTrue(row.supportsDpiButtonBinding, "\(row.name): only a button MacRazer binds")
        }
        let none = ButtonRemapper(defaults: defaults(#function))
        none.setActiveDevice(nil)
        XCTAssertFalse(none.supportsDpiPrivateKeys, "no mouse")
    }

    // MARK: A gesture

    /// The long key starts a true hold: moves while it is held swipe, once, during the
    /// movement, and its release ends the hold with no click. Moves go through.
    func testTheLongKeyHoldsAndASwipeFiresOnce() {
        let emitted = Emitted()
        let r = remapper(emitted)
        key(r, keys.long, down: true)
        XCTAssertEqual(r.gestureHold?.trigger, ButtonRemapper.dpiButton)
        XCTAssertEqual(r.lastDetectedButton, ButtonRemapper.dpiButton)
        XCTAssertTrue(move(r, dy: -30), "moves go through")
        XCTAssertEqual(emitted.actions, [], "30 points is not a swipe yet")
        move(r, dy: -30)
        XCTAssertEqual(emitted.actions, [bindings.up], "fired during the movement")
        move(r, dx: 300)
        XCTAssertNotNil(r.gestureHold, "a swipe doesn't end the hold: the release does")
        key(r, keys.long, down: false)
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(emitted.actions, [bindings.up], "once per hold, and no click after it")
        XCTAssertEqual(emitted.dpiCycles, 0)
    }

    /// Each direction is its own action, as for a mouse button's gesture.
    func testEachDirectionFiresItsOwnAction() {
        let emitted = Emitted()
        let r = remapper(emitted)
        for (dx, dy) in [(Int64(0), Int64(80)), (-80, 0), (80, 0)] {
            key(r, keys.long, down: true)
            move(r, dx: dx, dy: dy)
            key(r, keys.long, down: false)
        }
        XCTAssertEqual(emitted.actions, [bindings.down, bindings.left, bindings.right])
    }

    /// A long hold released without a swipe is never the click (the short press is): it fires
    /// Hold, which is None here, so nothing at all.
    func testALongHoldWithoutASwipeIsNotAClick() {
        let emitted = Emitted()
        let r = remapper(emitted)
        key(r, keys.long, down: true)
        move(r, dx: 12, dy: -8)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.actions, [])
        XCTAssertEqual(emitted.dpiCycles, 0)
    }

    // MARK: Hold

    /// Holding the button without moving, then letting go, fires Hold once, at the release:
    /// nothing while it is held, as a swipe could still come. The short press stays the click,
    /// and never fires Hold. The user asked for a click and a hold set apart.
    func testALongPressReleasedInPlaceFiresHoldOnce() {
        let emitted = Emitted()
        let r = remapper(emitted, action: .gesture(withHold))
        key(r, keys.long, down: true)
        move(r, dx: 12, dy: -8)
        move(r, dx: -20, dy: 30)
        XCTAssertEqual(emitted.actions, [], "nothing while held")
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.actions, [mute], "Hold, at the release")
        XCTAssertNil(r.gestureHold)
        key(r, keys.long, down: false)
        move(r, dy: -100)
        XCTAssertEqual(emitted.actions, [mute], "once")

        shortPress(r)
        XCTAssertEqual(emitted.actions, [mute, bindings.click], "a short press is Click, not Hold")
        XCTAssertEqual(emitted.dpiCycles, 0)
    }

    /// A long press that swiped is the swipe's: its release fires no Hold.
    func testAHoldThatSwipedDoesNotFireHold() {
        let emitted = Emitted()
        let r = remapper(emitted, action: .gesture(withHold))
        key(r, keys.long, down: true)
        move(r, dy: -80)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.actions, [bindings.up], "the swipe, and no Hold after it")
        key(r, keys.long, down: true)
        move(r, dx: 80)
        move(r, dx: -80)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.actions, [bindings.up, bindings.right], "out and back is still a swipe")
    }

    /// Hold on DPI Cycle steps the DPI stage once per long press released in place, as Click
    /// on DPI Cycle does for a short press. Hold on None does nothing, and asks for no cycle.
    func testHoldOnDpiCycleCyclesOncePerLongPress() {
        let emitted = Emitted()
        var cycling = bindings
        cycling.hold = .dpiCycle
        let r = remapper(emitted, action: .gesture(cycling))
        key(r, keys.long, down: true)
        XCTAssertEqual(emitted.dpiCycles, 0, "not while held")
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.dpiCycles, 1)
        key(r, keys.long, down: true)
        move(r, dy: 80)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.dpiCycles, 1, "not after a swipe")
        XCTAssertEqual(emitted.actions, [bindings.down])
        shortPress(r)
        XCTAssertEqual(emitted.actions, [bindings.down, bindings.click], "Click is its own")
        XCTAssertEqual(emitted.dpiCycles, 1)
    }

    /// The short key fires the Click slot, at once, and starts no hold.
    func testTheShortKeyIsTheClick() {
        let emitted = Emitted()
        let r = remapper(emitted)
        key(r, keys.short, down: true)
        XCTAssertEqual(emitted.actions, [bindings.click])
        XCTAssertNil(r.gestureHold)
        key(r, keys.short, down: false)
        move(r, dy: -100)
        XCTAssertEqual(emitted.actions, [bindings.click], "the key's release does nothing")
        XCTAssertEqual(emitted.dpiCycles, 0)
    }

    /// With Click on None a short press does nothing at all: no action, and no DPI cycle,
    /// which the firmware doesn't do either in driver mode.
    func testAShortPressWithClickOnNoneDoesNothing() {
        let emitted = Emitted()
        var quiet = bindings
        quiet.click = .passthrough
        let r = remapper(emitted, action: .gesture(quiet))
        shortPress(r)
        shortPress(r)
        XCTAssertEqual(emitted.dpiCycles, 0, "None asks for no cycle")
        XCTAssertEqual(emitted.actions, [])
        XCTAssertNil(r.gestureHold)
    }

    /// With Click on DPI Cycle a short press steps the DPI stage as the firmware would have:
    /// exactly one cycle per press, and nothing else. The short key's release adds none.
    func testAShortPressWithClickOnDpiCycleCyclesOncePerPress() {
        let emitted = Emitted()
        var cycling = bindings
        cycling.click = .dpiCycle
        let r = remapper(emitted, action: .gesture(cycling))
        key(r, keys.short, down: true)
        XCTAssertEqual(emitted.dpiCycles, 1, "at the press")
        key(r, keys.short, down: false)
        XCTAssertEqual(emitted.dpiCycles, 1, "nothing at the release")
        shortPress(r)
        shortPress(r)
        XCTAssertEqual(emitted.dpiCycles, 3, "one cycle per press")
        XCTAssertEqual(emitted.actions, [], "DPI Cycle is never posted as an action")
    }

    /// DPI Cycle in a direction steps the DPI stage once, when the swipe fires, as any other
    /// action in a slot does.
    func testDpiCycleInADirectionCyclesOncePerSwipe() {
        let emitted = Emitted()
        var cycling = bindings
        cycling.up = .dpiCycle
        let r = remapper(emitted, action: .gesture(cycling))
        key(r, keys.long, down: true)
        move(r, dy: -80)
        move(r, dy: -80)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.dpiCycles, 1)
        XCTAssertEqual(emitted.actions, [])
        key(r, keys.long, down: true)
        move(r, dy: 80)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.actions, [bindings.down], "the other directions are unchanged")
        XCTAssertEqual(emitted.dpiCycles, 1)
    }

    /// DPI Cycle does nothing anywhere but a slot of this mouse's DPI gesture in driver mode:
    /// as the DPI button's whole action, before driver mode is engaged, in a side button's
    /// gesture or as a side button's mapping. No action is posted and no cycle is asked for.
    func testDpiCycleIsInertAnywhereElse() {
        let everywhere = GestureBindings(click: .dpiCycle, up: .dpiCycle, down: .dpiCycle, left: .dpiCycle,
                                         right: .dpiCycle)
        let emitted = Emitted()
        let whole = remapper(emitted, action: .dpiCycle, name: "\(#function)-whole")
        shortPress(whole)
        key(whole, keys.long, down: true)
        move(whole, dy: -100)
        key(whole, keys.long, down: false)

        let notEngaged = remapper(emitted, action: .gesture(everywhere), engaged: false,
                                  name: "\(#function)-not engaged")
        shortPress(notEngaged)

        let side = remapper(emitted, action: nil, name: "\(#function)-side")
        side.saveDpiSoftwareAction(nil)
        side.setAction(.gesture(everywhere), for: 3)
        side.setAction(.dpiCycle, for: 4)
        func click(_ button: CGMouseButton, dy: Int64 = 0) {
            let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                               mouseButton: button)!
            down.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
            _ = side.handle(type: .otherMouseDown, event: down)
            if dy != 0 {
                let drag = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDragged, mouseCursorPosition: .zero,
                                   mouseButton: button)!
                drag.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
                drag.setIntegerValueField(.mouseEventDeltaY, value: dy)
                _ = side.handle(type: .otherMouseDragged, event: drag)
            }
            let up = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero,
                             mouseButton: button)!
            up.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
            _ = side.handle(type: .otherMouseUp, event: up)
        }
        let back = CGMouseButton(rawValue: 3)!, forward = CGMouseButton(rawValue: 4)!
        click(back)
        click(back, dy: -100)
        click(forward)

        XCTAssertEqual(emitted.actions, [])
        XCTAssertEqual(emitted.dpiCycles, 0)
    }

    // MARK: Another action

    /// An action that isn't a gesture fires on the short key, and a long press does nothing.
    func testAnotherActionFiresOnTheShortKeyAndALongPressDoesNothing() {
        let emitted = Emitted()
        let media = RemapAction.mediaKey(code: 7, name: "Mute")
        let r = remapper(emitted, action: media)
        shortPress(r)
        XCTAssertEqual(emitted.actions, [media])
        key(r, keys.long, down: true)
        XCTAssertNil(r.gestureHold, "no hold")
        XCTAssertTrue(move(r, dy: -100))
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.actions, [media], "nothing for the long press")
        XCTAssertEqual(emitted.dpiCycles, 0, "the button is remapped: no DPI cycle")
    }

    // MARK: When keys count

    /// Keys count only while driver mode is engaged on the connected mouse with an action
    /// saved: not before it is engaged, nor after it failed or went, nor while the mouse is
    /// offline, nor with DPI Cycle (default) chosen. A code that isn't the button's does nothing.
    func testKeysCountOnlyWhileDriverModeIsEngaged() {
        let cases: [(String, (ButtonRemapper) -> Void)] = [
            ("off", { $0.dpiDriverModeChanged(.off) }),
            ("engaging", { $0.dpiDriverModeChanged(.engaging) }),
            ("unavailable", { $0.dpiDriverModeChanged(.unavailable("The mouse didn't accept it.")) }),
            ("paused", { $0.remappingPaused = true }),
            ("no action", { $0.saveDpiSoftwareAction(nil) }),
        ]
        for (name, setUp) in cases {
            let emitted = Emitted()
            let r = remapper(emitted, name: "\(#function)-\(name)")
            setUp(r)
            shortPress(r)
            key(r, keys.long, down: true)
            XCTAssertNil(r.gestureHold, name)
            move(r, dy: -100)
            key(r, keys.long, down: false)
            XCTAssertEqual(emitted.actions, [], name)
            XCTAssertEqual(emitted.dpiCycles, 0, name)
        }
        let emitted = Emitted()
        let r = remapper(emitted, name: "\(#function)-other code")
        key(r, 0x30, down: true)
        key(r, 0x30, down: false)
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(emitted.actions, [])
    }

    /// The Basilisk has no private keys: its DPI button goes through F20, and keys handed to
    /// its remapper do nothing, engaged or not.
    func testTheBasiliskIgnoresPrivateKeys() {
        let emitted = Emitted()
        let r = ButtonRemapper(defaults: defaults(#function), actionEmitter: { emitted.actions.append($0) })
        r.setActiveDevice("PM2533", deviceID: basilisk)
        r.saveDpiSoftwareAction(.gesture(bindings))
        r.dpiDriverModeChanged(.engaged)
        XCTAssertFalse(r.privateKeysActive)
        shortPress(r)
        key(r, keys.long, down: true)
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(emitted.actions, [])
    }

    /// The ways a hold of the long key ends early: pausing, driver mode lost or failed, the
    /// action or its Hold changing, a profile, a mouse button going down, the tap switched off
    /// for a moment, another mouse, and the Mac waking. None fires anything, and the long
    /// key's release after it fires nothing either, Hold included: the hold never moved, so
    /// only a reset that let its release through would fire it.
    func testEveryResetEndsTheHoldAndItsReleaseFiresNothing() {
        let endings: [(String, (ButtonRemapper) -> Void)] = [
            ("paused", { $0.remappingPaused = true }),
            ("driver mode lost", { $0.dpiDriverModeChanged(.off) }),
            ("driver mode failed", { $0.dpiDriverModeChanged(.unavailable("The mouse didn't confirm.")) }),
            ("action changed", { $0.saveDpiSoftwareAction(.doubleClick) }),
            ("Hold changed", { $0.setGestureAction(.doubleClick, for: .hold, of: ButtonRemapper.dpiButton) }),
            ("profile", { $0.setMappings([:]) }),
            ("mouse button", { r in
                let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                                    mouseButton: .center)!
                _ = r.handle(type: .otherMouseDown, event: event)
            }),
            ("tap disabled", { _ = $0.handle(type: .tapDisabledByTimeout, event: CGEvent(source: nil)!) }),
            ("device change", { $0.setActiveDevice("OTHER-BT", deviceID: 0x00DC) }),
            ("wake", { $0.cancelGesture() }),
        ]
        for (name, end) in endings {
            let emitted = Emitted()
            let r = remapper(emitted, action: .gesture(withHold), name: "\(#function)-\(name)")
            key(r, keys.long, down: true)
            move(r, dy: -30)
            end(r)
            XCTAssertNil(r.gestureHold, "\(name) ends the hold")
            XCTAssertTrue(move(r, dy: -100), name)
            key(r, keys.long, down: false)
            XCTAssertEqual(emitted.actions, [], "\(name): no swipe, no click, no Hold")
            XCTAssertEqual(emitted.dpiCycles, 0, name)
        }
    }

    // MARK: Watching the keys

    /// The keys are watched exactly while driver mode is engaged on this mouse, and they reach
    /// the remapper from there.
    func testTheKeysAreWatchedOnlyWhileDriverModeIsEngaged() {
        let emitted = Emitted()
        let source = FakeSource()
        let r = remapper(emitted, engaged: false, source: source)
        XCTAssertEqual(source.starts, [], "not before driver mode")
        r.dpiDriverModeChanged(.engaging)
        XCTAssertEqual(source.starts, [])
        r.dpiDriverModeChanged(.engaged)
        XCTAssertEqual(source.starts, [cobra])
        XCTAssertTrue(source.isRunning)
        source.send(keys.short, down: true)
        XCTAssertEqual(emitted.actions, [bindings.click], "through the source")

        r.dpiDriverModeChanged(.unavailable("The mouse didn't confirm."))
        XCTAssertFalse(source.isRunning, "stopped as driver mode goes")
        r.dpiDriverModeChanged(.engaged)
        XCTAssertTrue(source.isRunning)
        r.setActiveDevice("PM2533", deviceID: basilisk)
        XCTAssertFalse(source.isRunning, "another mouse")
    }

    /// Keys that can't be watched (the mouse's HID device wouldn't open) are remembered, so
    /// driver mode is no longer wanted (the button goes back to cycling DPI rather than doing
    /// nothing), and the controller hears so. Not for the rest of the run: a look at the
    /// permissions tries to open the mouse again, without touching it, and once it opens the
    /// block is gone.
    func testKeysThatCantBeWatchedGiveTheButtonBackUntilTheyOpen() {
        let emitted = Emitted()
        let source = FakeSource()
        source.refuses = true
        var wanted: [Bool] = []
        let r = remapper(emitted, engaged: false, source: source)
        r.onDpiDriverModeWanted = { wanted.append($0) }
        XCTAssertFalse(r.privateKeyInputBlocked)
        r.dpiDriverModeChanged(.engaged)
        XCTAssertEqual(source.starts, [cobra])
        XCTAssertTrue(r.privateKeyInputBlocked)
        XCTAssertEqual(wanted, [false])

        r.retryBlockedPrivateKeys()
        XCTAssertEqual(source.checks, [cobra], "an open check, not a start")
        XCTAssertTrue(r.privateKeyInputBlocked, "still refused")
        source.refuses = false
        r.retryBlockedPrivateKeys()
        XCTAssertEqual(source.checks, [cobra, cobra])
        XCTAssertFalse(r.privateKeyInputBlocked, "it opens now: driver mode can be wanted again")
        r.retryBlockedPrivateKeys()
        XCTAssertEqual(source.checks, [cobra, cobra], "nothing to check once unblocked")
        XCTAssertEqual(source.starts, [cobra], "the keys are watched again only once driver mode is")
    }

    /// What a start of the watcher counts as working: any of the mouse's devices open. With
    /// none there, a manager that opened waits for the mouse; one refused for Input Monitoring
    /// is a failure, to be tried again, rather than a watch that never delivers a key.
    func testAWatchWorksOnlyWithADeviceOpenOrAManagerWaitingForOne() {
        let notPermitted = IOReturn(bitPattern: 0xE00002E2)
        XCTAssertTrue(DpiPrivateKeyWatcher.startWorks(managerOpen: kIOReturnSuccess, present: 2, opened: 2))
        XCTAssertTrue(DpiPrivateKeyWatcher.startWorks(managerOpen: notPermitted, present: 2, opened: 1),
                      "one device is enough")
        XCTAssertTrue(DpiPrivateKeyWatcher.startWorks(managerOpen: kIOReturnSuccess, present: 0, opened: 0),
                      "waiting for the mouse to show up")
        XCTAssertFalse(DpiPrivateKeyWatcher.startWorks(managerOpen: notPermitted, present: 0, opened: 0),
                       "refused, with nothing to see")
        XCTAssertFalse(DpiPrivateKeyWatcher.startWorks(managerOpen: notPermitted, present: 2, opened: 0))
        XCTAssertFalse(DpiPrivateKeyWatcher.startWorks(managerOpen: kIOReturnSuccess, present: 2, opened: 0))
    }

    // MARK: Wanting driver mode

    /// Driver mode is wanted only for a mouse with private keys, with an action of MacRazer's,
    /// and with what it takes to carry it out. Input Monitoring is asked last, and only then.
    /// What is missing is named, in that order: Accessibility, Input Monitoring, a reopen.
    func testDriverModeIsWantedOnlyWithEverythingItNeeds() {
        var asked = 0
        func need(_ privateKeys: Bool, _ action: RemapAction?, _ permissions: Bool, _ monitoring: Bool,
                  blocked: Bool = false) -> DpiDriverModeNeed {
            DpiDriverModeNeed(privateKeys: privateKeys, action: action, permissions: permissions,
                              inputMonitoring: { asked += 1; return monitoring }, keysBlocked: blocked)
        }
        let gesture = RemapAction.gesture(bindings)
        XCTAssertEqual(need(true, gesture, true, true), .ready)
        XCTAssertEqual(need(true, .doubleClick, true, true), .ready)
        asked = 0
        XCTAssertEqual(need(false, gesture, true, true), DpiDriverModeNeed.none, "the Basilisk")
        XCTAssertEqual(need(true, nil, true, true), DpiDriverModeNeed.none,
                       "DPI Cycle (default), or a function the mouse runs itself")
        XCTAssertEqual(need(true, gesture, false, true), .accessibility, "no event tap")
        XCTAssertEqual(need(true, gesture, false, false, blocked: true), .accessibility)
        XCTAssertEqual(asked, 0, "Input Monitoring isn't asked when something else is missing")
        XCTAssertEqual(need(true, gesture, true, false), .inputMonitoring)
        XCTAssertEqual(need(true, gesture, true, false, blocked: true), .inputMonitoring,
                       "not granted is what is missing, whatever a start said earlier")
        XCTAssertEqual(need(true, gesture, true, true, blocked: true), .relaunch)
        XCTAssertEqual(asked, 3)

        let all: [DpiDriverModeNeed] = [.none, .ready, .accessibility, .inputMonitoring, .relaunch]
        XCTAssertEqual(all.filter(\.wantsDriverMode), [.ready])
        XCTAssertEqual(all.filter(\.waitsForPermission), [.accessibility, .inputMonitoring])
    }

    /// Input Monitoring turned on while MacRazer runs took effect only once it was reopened
    /// (macOS 26.3: `IOHIDCheckAccess` in the running app kept saying not granted, and the
    /// 3-second look never ended). So a missing Input Monitoring asks for a reopen, as a grant
    /// not yet applied does. Accessibility applies to the running app, and asks for none.
    func testInputMonitoringAsksForAReopenAndAccessibilityDoesNot() {
        let all: [DpiDriverModeNeed] = [.none, .ready, .accessibility, .inputMonitoring, .relaunch]
        XCTAssertEqual(all.filter(\.needsReopen), [.inputMonitoring, .relaunch])
        XCTAssertTrue(DpiDriverModeNeed.inputMonitoring.rechecksPermissions(paused: false),
                      "still looked at, harmless if macOS ever applies it to the running app")
    }

    /// The reopen opens a new instance of this app, and quits this one only once it launched,
    /// through the quit it is given (`NSApp.terminate` in the app, which puts driver mode back
    /// in `applicationWillTerminate` as Quit does). A failed open doesn't quit, and says so.
    func testTheReopenQuitsOnlyOnceTheNewInstanceLaunched() {
        final class Quits: @unchecked Sendable { var count = 0 }
        struct OpenFailed: Error {}
        for launches in [true, false] {
            let r = ButtonRemapper(defaults: defaults("\(#function)-\(launches)"), actionEmitter: { _ in })
            let quits = Quits()
            // Either answer ends the wait: the quit, or the failure being said.
            let answered = expectation(description: "the open answered")
            let failure = r.$reopenFailed.filter { $0 }.sink { _ in answered.fulfill() }
            let opener: AppRelaunch.Opener = { url, config, completion in
                XCTAssertEqual(url, Bundle.main.bundleURL)
                XCTAssertTrue(config.createsNewApplicationInstance)
                // LaunchServices answers on a queue of its own.
                DispatchQueue.global().async {
                    completion(launches ? NSRunningApplication.current : nil, launches ? nil : OpenFailed())
                }
            }
            r.reopenApp(opener: opener, quit: {
                XCTAssertTrue(Thread.isMainThread)
                quits.count += 1
                answered.fulfill()
            })
            wait(for: [answered], timeout: 5)
            failure.cancel()
            XCTAssertEqual(quits.count, launches ? 1 : 0, "launched: \(launches)")
            XCTAssertEqual(r.reopenFailed, !launches, "launched: \(launches)")
        }
        XCTAssertFalse(ButtonRemapper.reopenFailedText.contains("\u{2014}"), "no em dash")
    }

    /// The permissions are looked at every few seconds only while driver mode waits for one
    /// of them and the mouse is connected: not when it is wanted and ready, not needed, nor
    /// waiting for a reopen that looking again can't bring.
    func testThePermissionsAreLookedAtAgainOnlyWhileOneIsAllThatsMissing() {
        XCTAssertTrue(DpiDriverModeNeed.accessibility.rechecksPermissions(paused: false))
        XCTAssertTrue(DpiDriverModeNeed.inputMonitoring.rechecksPermissions(paused: false))
        for need: DpiDriverModeNeed in [.accessibility, .inputMonitoring] {
            XCTAssertFalse(need.rechecksPermissions(paused: true), "\(need): the mouse is away")
        }
        for need: DpiDriverModeNeed in [.none, .ready, .relaunch] {
            XCTAssertFalse(need.rechecksPermissions(paused: false), "\(need)")
        }
        XCTAssertGreaterThanOrEqual(ButtonRemapper.permissionRecheckInterval, 1)
        XCTAssertLessThanOrEqual(ButtonRemapper.permissionRecheckInterval, 10, "a few seconds")
    }

    /// The remapper waits for a permission exactly while the rules above say so: here, where
    /// tests have no event tap, while the DPI button has an action of MacRazer's on a
    /// connected Cobra. It stops as the action goes, the mouse goes offline or is another.
    func testTheRemapperWaitsForAPermissionOnlyWhileItMatters() {
        let emitted = Emitted()
        let r = remapper(emitted, engaged: false)
        var wanted: [Bool] = []
        r.onDpiDriverModeWanted = { wanted.append($0) }
        XCTAssertFalse(r.waitsForPermission, "nothing has looked yet")
        r.saveDpiSoftwareAction(.doubleClick)
        XCTAssertTrue(r.waitsForPermission, "no Accessibility in tests")
        XCTAssertEqual(r.currentDpiDriverModeNeed, .accessibility)
        r.remappingPaused = true
        XCTAssertFalse(r.waitsForPermission, "the mouse is away")
        r.remappingPaused = false
        XCTAssertTrue(r.waitsForPermission)
        r.saveDpiSoftwareAction(nil)
        XCTAssertFalse(r.waitsForPermission, "DPI Cycle (default) needs nothing")
        r.saveDpiSoftwareAction(.gesture(bindings))
        XCTAssertTrue(r.waitsForPermission)
        r.setActiveDevice("PM2533", deviceID: basilisk)
        XCTAssertFalse(r.waitsForPermission, "the Basilisk has no driver mode")
        XCTAssertEqual(wanted, [false], "never wanted without the permissions")
    }

    /// The controller hears each change once, not every time the remapper looks.
    func testTheControllerHearsEachChangeOnce() {
        let emitted = Emitted()
        let r = remapper(emitted, engaged: false)
        var wanted: [Bool] = []
        r.onDpiDriverModeWanted = { wanted.append($0) }
        r.saveDpiSoftwareAction(.doubleClick)
        r.saveDpiSoftwareAction(.gesture(bindings))
        r.setMappings([:])
        XCTAssertEqual(wanted, [false], "no event tap in tests, so not wanted, and said once")
    }

    // MARK: The tap

    /// The pointer's moves are asked for while the DPI button is a gesture on this mouse, and
    /// no key events ever are: no F20 is involved, so a keyboard's typing never goes through
    /// the tap for it. The Basilisk's mask is as before.
    func testTheTapAsksForPointerMovesWithoutKeysOnThisMouse() {
        let moved = CGEventMask(1) << CGEventType.mouseMoved.rawValue
        for gestures in [false, true] {
            let mask = ButtonRemapper.eventMask(keyboard: false, gestures: gestures, privateKeyGesture: true)
            XCTAssertNotEqual(mask & moved, 0)
            XCTAssertFalse(ButtonRemapper.includesKeyboardEvents(mask))
            XCTAssertEqual(ButtonRemapper.eventMask(keyboard: false, gestures: gestures) & moved, 0)
        }

        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertNotEqual(r.wantedEventMask & moved, 0, "a gesture")
        XCTAssertFalse(ButtonRemapper.includesKeyboardEvents(r.wantedEventMask))
        r.saveDpiSoftwareAction(.mediaKey(code: 16, name: "Play / Pause"))
        XCTAssertEqual(r.wantedEventMask & moved, 0, "a media key needs no movement")
        XCTAssertFalse(ButtonRemapper.includesKeyboardEvents(r.wantedEventMask), "nor keys")
        r.saveDpiSoftwareAction(nil)
        XCTAssertEqual(r.wantedEventMask, ButtonRemapper.eventMask(keyboard: false, gestures: false))

        // The Basilisk's mask is as before: the keys for its F20, and never the pointer's moves,
        // as no hold of its DPI button exists.
        let bridge = ButtonRemapper(defaults: defaults("\(#function)-basilisk"), actionEmitter: { _ in })
        bridge.setActiveDevice("PM2533", deviceID: basilisk)
        bridge.saveDpiSoftwareAction(.doubleClick)
        XCTAssertEqual(bridge.wantedEventMask, ButtonRemapper.eventMask(keyboard: true, gestures: false))
        bridge.saveDpiSoftwareAction(.gesture(bindings))
        XCTAssertEqual(bridge.wantedEventMask & moved, 0)
    }

    /// F20 typed on this mouse's Mac (a real keyboard, or an entry not yet cleared) is never
    /// taken: it goes through, press and release.
    func testF20IsNeverTakenOnThisMouse() {
        let emitted = Emitted()
        let r = remapper(emitted)
        r.confirmDpiBridge(binding: .softwareBridge)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 90, keyDown: down)!
            event.flags = []
            XCTAssertNotNil(r.handle(type: down ? .keyDown : .keyUp, event: event), "F20 \(down ? "down" : "up")")
        }
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(emitted.actions, [])
    }

    // MARK: Choosing

    /// An action of MacRazer's leaves the entry on DPI Cycle on this mouse, so the button is
    /// stock with MacRazer closed; the mouse's own functions are written as everywhere.
    func testAnActionOfMacRazersKeepsDpiCycleOnThisMouse() {
        func assignment(_ action: RemapAction) -> (BLEProtocol.DPIButtonBinding, RemapAction?) {
            let a = ButtonRemapper.dpiButtonAssignment(for: action, privateKeys: true)!
            return (a.binding, a.softwareAction)
        }
        let f13 = RemapAction.keystroke(keyCode: 105, modifiers: 0, name: "F13")
        for action in [f13, .doubleClick, .mediaKey(code: 16, name: "Play / Pause"), .launchpad, .gesture(bindings)] {
            XCTAssertEqual(assignment(action).0, .dpiCycle, action.label)
            XCTAssertEqual(assignment(action).1, action, action.label)
        }
        XCTAssertEqual(assignment(.passthrough).0, .dpiCycle)
        XCTAssertNil(assignment(.passthrough).1, "DPI Cycle (default) clears the action")
        for privateKeys in [true, false] {
            let a = ButtonRemapper.dpiButtonAssignment(for: .dpiCycle, privateKeys: privateKeys)
            XCTAssertEqual(a?.binding, .dpiCycle, "the whole button cycling DPI is the firmware's DPI Cycle")
            XCTAssertNil(a?.softwareAction)
        }
        let copy = ButtonRemapper.presets.first { $0.id == "copy" }!.action
        XCTAssertEqual(assignment(copy).0, .keyboardShortcut(hidUsage: 0x06, modifiers: 0x08), "⌘C, typed by the mouse")
        XCTAssertNil(assignment(copy).1)
        XCTAssertEqual(assignment(.mouseButton(button: 3, name: "Back Button")).0, .back)
    }

    /// The menu names the action MacRazer carries out over the DPI Cycle the entry holds, and
    /// DPI Cycle itself without one.
    func testTheMenuNamesTheActionOverDpiCycle() {
        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertEqual(r.dpiCycleLabel(for: .dpiCycle), "Gesture (MacRazer)")
        XCTAssertEqual(r.dpiCycleLabel(for: .softwareBridge), "Gesture (MacRazer)")
        XCTAssertEqual(r.dpiCycleLabel(for: .back), "Back")
        r.saveDpiSoftwareAction(nil)
        XCTAssertEqual(r.dpiCycleLabel(for: .dpiCycle), "DPI Cycle (default)")
    }

    /// The gesture editor's menus start with None and, for the DPI button on this mouse, DPI
    /// Cycle beside it as a choice of its own, in every slot. No other button, and the DPI
    /// button of no other mouse, offers DPI Cycle.
    func testTheDpiGestureMenusOfferNoneAndDpiCycleOnThisMouseOnly() {
        let dpi = ButtonRemapper.dpiButton
        XCTAssertEqual(ButtonRemapper.gestureSlotLeadingChoices(button: dpi, privateKeys: true), [.passthrough, .dpiCycle])
        XCTAssertEqual(ButtonRemapper.gestureSlotLeadingChoices(button: dpi, privateKeys: true).map(\.label),
                       ["None", "DPI Cycle"])
        XCTAssertEqual(ButtonRemapper.gestureSlotLeadingChoices(button: dpi, privateKeys: false), [.passthrough],
                       "the Basilisk: software can't cycle its DPI")
        for button in [2, 3, 4, 5] {
            XCTAssertEqual(ButtonRemapper.gestureSlotLeadingChoices(button: button, privateKeys: true), [.passthrough],
                           ButtonRemapper.label(for: button))
        }

        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertEqual(r.gestureSlotLeadingChoices(of: dpi), [.passthrough, .dpiCycle])
        XCTAssertEqual(r.gestureSlotLeadingChoices(of: 3), [.passthrough])
        let basilisk = ButtonRemapper(defaults: defaults("\(#function)-basilisk"), actionEmitter: { _ in })
        basilisk.setActiveDevice("PM2533", deviceID: self.basilisk)
        XCTAssertEqual(basilisk.gestureSlotLeadingChoices(of: dpi), [.passthrough])
    }

    /// Each slot shows its action's label: None for none, DPI Cycle for DPI Cycle, which are
    /// two different choices now. Hold among them.
    func testTheEditorNamesNoneAndDpiCycleApart() {
        let dpi = ButtonRemapper.dpiButton
        let emitted = Emitted()
        var quiet = GestureBindings.defaults(click: .dpiCycle)
        quiet.down = .passthrough
        let r = remapper(emitted, action: .gesture(quiet))
        XCTAssertEqual(r.gestureSlotLabel(.click, of: dpi), "DPI Cycle")
        XCTAssertEqual(r.gestureSlotLabel(.hold, of: dpi), "None")
        XCTAssertEqual(r.gestureSlotLabel(.down, of: dpi), "None")
        XCTAssertEqual(r.gestureSlotLabel(.up, of: dpi), quiet.up.label)
        r.setGestureAction(.passthrough, for: .click, of: dpi)
        XCTAssertEqual(r.gestureSlotLabel(.click, of: dpi), "None")
        r.setGestureAction(.dpiCycle, for: .left, of: dpi)
        XCTAssertEqual(r.gestureSlotLabel(.left, of: dpi), "DPI Cycle")
        r.setGestureAction(.dpiCycle, for: .hold, of: dpi)
        XCTAssertEqual(r.gestureSlotLabel(.hold, of: dpi), "DPI Cycle")
        XCTAssertEqual(r.gestureSlotLabel(.click, of: dpi), "None", "Hold and Click are set apart")
        r.setGestureAction(.doubleClick, for: .click, of: dpi)
        XCTAssertEqual(r.gestureSlotLabel(.click, of: dpi), "Double Click")
        XCTAssertEqual(r.gestureSlotLabel(.click, of: 3), "None", "not a gesture")
    }

    /// The editor lists Hold only for the DPI button of this mouse, the one button with a short
    /// and a long press, right after Click: Click, Hold, then the four swipes. A side button,
    /// and the Basilisk's DPI button (F20), press and release in place as their Click, so Hold
    /// would never fire there and isn't offered. Hold's menu starts as Click's does.
    func testTheEditorListsHoldOnlyForThisMousesDpiButton() {
        let dpi = ButtonRemapper.dpiButton
        XCTAssertEqual(ButtonRemapper.gestureSlots(button: dpi, privateKeys: true),
                       [.click, .hold, .up, .down, .left, .right])
        XCTAssertEqual(ButtonRemapper.gestureSlots(button: dpi, privateKeys: true).map(\.title),
                       ["Click", "Hold", "Swipe Up", "Swipe Down", "Swipe Left", "Swipe Right"])
        XCTAssertEqual(ButtonRemapper.gestureSlots(button: dpi, privateKeys: false),
                       [.click, .up, .down, .left, .right], "the Basilisk")
        for button in [2, 3, 4, 5] {
            XCTAssertEqual(ButtonRemapper.gestureSlots(button: button, privateKeys: true),
                           [.click, .up, .down, .left, .right], ButtonRemapper.label(for: button))
        }

        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertTrue(r.gestureSlots(of: dpi).contains(.hold))
        XCTAssertFalse(r.gestureSlots(of: 3).contains(.hold))
        XCTAssertEqual(r.gestureSlotLeadingChoices(of: dpi), [.passthrough, .dpiCycle], "None and DPI Cycle, as Click")
        let basilisk = ButtonRemapper(defaults: defaults("\(#function)-basilisk"), actionEmitter: { _ in })
        basilisk.setActiveDevice("PM2533", deviceID: self.basilisk)
        XCTAssertFalse(basilisk.gestureSlots(of: dpi).contains(.hold))
    }

    /// A gesture as the DPI action survives the trip through UserDefaults, the way a relaunch
    /// reads it back.
    func testAGestureDpiActionIsSavedAndReadBack() {
        let shared = defaults(#function)
        let first = ButtonRemapper(defaults: shared)
        first.setActiveDevice("COBRA-BT", deviceID: cobra)
        first.saveDpiSoftwareAction(.gesture(bindings))

        let second = ButtonRemapper(defaults: shared)
        second.setActiveDevice("COBRA-BT", deviceID: cobra)
        XCTAssertEqual(second.dpiCycleSoftwareAction, .gesture(bindings))
        XCTAssertEqual(second.gestureBindings(for: ButtonRemapper.dpiButton), bindings)
    }

    /// The gesture editor edits the DPI button's gesture as it does a mouse button's: each
    /// change is saved, nothing goes into the mouse buttons' table, and a nested gesture is
    /// refused.
    func testTheGestureEditorEditsTheDpiGesture() {
        let shared = defaults(#function)
        let r = ButtonRemapper(defaults: shared)
        r.setActiveDevice("COBRA-BT", deviceID: cobra)
        r.saveDpiSoftwareAction(.gesture(bindings))
        let dpi = ButtonRemapper.dpiButton
        r.setGestureAction(.doubleClick, for: .up, of: dpi)
        XCTAssertEqual(r.gestureBindings(for: dpi)?.up, .doubleClick)
        r.setGestureAction(.gesture(bindings), for: .down, of: dpi)
        XCTAssertEqual(r.gestureBindings(for: dpi)?.down, bindings.down, "no gesture inside a gesture")
        r.makeGesture(dpi)
        XCTAssertEqual(r.mappings, [:], "the DPI button is never a row of the mouse buttons' table")
        XCTAssertEqual(ButtonRemapper.label(for: dpi), "DPI Button")

        let reread = ButtonRemapper(defaults: shared)
        reread.setActiveDevice("COBRA-BT", deviceID: cobra)
        XCTAssertEqual(reread.gestureBindings(for: dpi)?.up, .doubleClick, "saved as it's made")
    }

    /// The Basilisk V3 X keeps exactly the choices its F20 bridge always had: the mouse's own
    /// functions, and Double Click and the media keys through F20. A key it can't type, a
    /// gesture or Launchpad would be new to its bridge, so they aren't taken there.
    func testTheBasiliskKeepsTheChoicesItsBridgeAlwaysHad() {
        func assignment(_ action: RemapAction) -> (BLEProtocol.DPIButtonBinding, RemapAction?)? {
            ButtonRemapper.dpiButtonAssignment(for: action, privateKeys: false).map { ($0.binding, $0.softwareAction) }
        }
        let copy = ButtonRemapper.presets.first { $0.id == "copy" }!.action
        XCTAssertEqual(assignment(copy)?.0, .keyboardShortcut(hidUsage: 0x06, modifiers: 0x08), "⌘C, typed by the mouse")
        XCTAssertNil(assignment(copy)?.1)
        XCTAssertEqual(assignment(.mouseButton(button: 2, name: "Middle Click"))?.0, .middleClick)
        XCTAssertEqual(assignment(.mouseButton(button: 0, name: "Left Click"))?.0, .leftClick)
        XCTAssertEqual(assignment(.passthrough)?.0, .dpiCycle)
        for action in [RemapAction.doubleClick, .mediaKey(code: 16, name: "Play / Pause")] {
            XCTAssertEqual(assignment(action)?.0, .softwareBridge, action.label)
            XCTAssertEqual(assignment(action)?.1, action, action.label)
        }
        let f13 = RemapAction.keystroke(keyCode: 105, modifiers: 0, name: "F13")
        for action in [f13, .launchpad, .gesture(bindings), .mouseButton(button: 8, name: "Button 9")] {
            XCTAssertNil(assignment(action), action.label)
        }
        XCTAssertTrue(ButtonRemapper.presets.allSatisfy { assignment($0.action)?.1 == nil },
                      "every preset is a key the mouse types itself, as before")
    }

    // MARK: A new gesture, and one saved before

    /// A new DPI gesture clicks None, on this mouse too: the user made the gesture again and a
    /// short press kept changing DPI, which surprised. Hold starts as None as well, and DPI
    /// Cycle is still a choice. On the Basilisk the same; any other button keeps its own click.
    func testANewDpiGestureClicksAndHoldsNone() {
        let dpi = ButtonRemapper.dpiButton
        XCTAssertEqual(GestureBindings.defaults(for: dpi).click, .passthrough)
        XCTAssertEqual(GestureBindings.defaults(for: dpi).hold, .passthrough)
        XCTAssertEqual(GestureBindings.defaults(for: 3).click, ButtonRemapper.originalClick(for: 3))
        XCTAssertEqual(GestureBindings.defaults(for: 3).hold, .passthrough)

        let emitted = Emitted()
        let r = remapper(emitted, action: nil)
        XCTAssertEqual(r.newDpiGesture, .gesture(.defaults(click: .passthrough)))
        r.saveDpiSoftwareAction(r.newDpiGesture)
        shortPress(r)
        key(r, keys.long, down: true)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.dpiCycles, 0, "a short or long press of a new gesture leaves DPI alone")
        XCTAssertEqual(emitted.actions, [])
        XCTAssertTrue(r.gestureSlotLeadingChoices(of: dpi).contains(.dpiCycle), "DPI Cycle stays a choice")

        XCTAssertNil(ButtonRemapper.dpiButtonAssignment(for: r.newDpiGesture, privateKeys: false),
                     "the Basilisk's DPI button is never a gesture")
    }

    /// What is saved now for a DPI gesture made before Hold existed: Click on DPI Cycle and the
    /// four directions, with no `hold` key. It reads with Hold on None, so it works as it did:
    /// a short press still cycles DPI, and a long press released in place does nothing. Saved
    /// again, it is written in the same shape, with no `hold`, so the mappings, the DPI
    /// button's action and the profiles don't change for anyone who never sets Hold. A Hold
    /// that is set is written and read back.
    func testAGestureSavedBeforeHoldReadsHoldAsNone() throws {
        let saved = #"""
        {"gesture":{"_0":{
          "click":{"dpiCycle":{}},
          "up":{"keystroke":{"keyCode":126,"modifiers":10747904,"name":"Mission Control  ⌃↑"}},
          "down":{"keystroke":{"keyCode":125,"modifiers":10747904,"name":"App Exposé  ⌃↓"}},
          "left":{"keystroke":{"keyCode":123,"modifiers":10747904,"name":"Space Left  ⌃←"}},
          "right":{"keystroke":{"keyCode":124,"modifiers":10747904,"name":"Space Right  ⌃→"}}
        }}}
        """#
        let decoded = try JSONDecoder().decode(RemapAction.self, from: Data(saved.utf8))
        XCTAssertEqual(decoded, .gesture(earlierLayout(click: .dpiCycle)))
        guard case .gesture(let bindings) = decoded else { return XCTFail("not a gesture") }
        XCTAssertEqual(bindings.hold, .passthrough)

        func savedKeys(_ action: RemapAction) throws -> Set<String> {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(action)) as? [String: Any]
            let gesture = object?["gesture"] as? [String: Any]
            return Set((gesture?["_0"] as? [String: Any])?.keys.map { $0 } ?? [])
        }
        XCTAssertEqual(try savedKeys(decoded), ["click", "up", "down", "left", "right"], "saved as it was")
        let profile = MouseProfile(name: "Old", dpi: 1600, pollRate: 1000, brightness: 50, effect: "",
                                   color: RGB(r: 0, g: 0, b: 0), buttonMappings: [3: decoded])
        let profileJSON = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        XCTAssertFalse(profileJSON.contains("\"hold\""), "nor in a profile")

        var holding = bindings
        holding.hold = mute
        XCTAssertEqual(try savedKeys(.gesture(holding)), ["click", "hold", "up", "down", "left", "right"])
        XCTAssertEqual(try JSONDecoder().decode(RemapAction.self, from: JSONEncoder().encode(RemapAction.gesture(holding))),
                       .gesture(holding))

        let store = defaults(#function)
        store.set(Data(saved.utf8), forKey: "dpiCycleSoftwareAction-COBRA-BT")
        let emitted = Emitted()
        let r = ButtonRemapper(defaults: store, actionEmitter: { emitted.actions.append($0) })
        r.onDpiCycleRequest = { emitted.dpiCycles += 1 }
        r.setActiveDevice("COBRA-BT", deviceID: cobra)
        r.dpiDriverModeChanged(.engaged)
        XCTAssertEqual(r.dpiCycleSoftwareAction, decoded, "loaded as saved")
        XCTAssertEqual(r.gestureSlotLabel(.hold, of: ButtonRemapper.dpiButton), "None")
        shortPress(r)
        XCTAssertEqual(emitted.dpiCycles, 1, "Click on DPI Cycle still cycles")
        key(r, keys.long, down: true)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.dpiCycles, 1, "Hold on None does nothing")
        XCTAssertEqual(emitted.actions, [])
    }

    /// What a build from before DPI Cycle was its own choice saved for the DPI gesture: Click
    /// on None, as `{"passthrough":{}}`. It reads as it was written, and a short press of it
    /// does nothing now, no DPI cycle included; it isn't turned into DPI Cycle. DPI Cycle
    /// itself is saved under a key of its own, and reads back.
    func testAGestureSavedBeforeDpiCycleKeepsNone() throws {
        let saved = #"""
        {"gesture":{"_0":{
          "click":{"passthrough":{}},
          "up":{"keystroke":{"keyCode":126,"modifiers":10747904,"name":"Mission Control  ⌃↑"}},
          "down":{"keystroke":{"keyCode":125,"modifiers":10747904,"name":"App Exposé  ⌃↓"}},
          "left":{"keystroke":{"keyCode":123,"modifiers":10747904,"name":"Space Left  ⌃←"}},
          "right":{"keystroke":{"keyCode":124,"modifiers":10747904,"name":"Space Right  ⌃→"}}
        }}}
        """#
        let decoded = try JSONDecoder().decode(RemapAction.self, from: Data(saved.utf8))
        XCTAssertEqual(decoded, .gesture(earlierLayout(click: .passthrough)))
        XCTAssertEqual(try JSONDecoder().decode(RemapAction.self, from: Data(#"{"passthrough":{}}"#.utf8)), .passthrough)

        let store = defaults(#function)
        store.set(Data(saved.utf8), forKey: "dpiCycleSoftwareAction-COBRA-BT")
        let emitted = Emitted()
        let r = ButtonRemapper(defaults: store, actionEmitter: { emitted.actions.append($0) })
        r.onDpiCycleRequest = { emitted.dpiCycles += 1 }
        r.setActiveDevice("COBRA-BT", deviceID: cobra)
        r.dpiDriverModeChanged(.engaged)
        XCTAssertEqual(r.dpiCycleSoftwareAction, decoded, "loaded as saved")
        XCTAssertEqual(r.gestureSlotLabel(.click, of: ButtonRemapper.dpiButton), "None")
        shortPress(r)
        XCTAssertEqual(emitted.dpiCycles, 0)
        XCTAssertEqual(emitted.actions, [])
        key(r, keys.long, down: true)
        move(r, dy: -80)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.actions, [earlierLayout(click: .passthrough).up],
                       "the gesture itself works as before, with what it was saved with")

        let encoded = try JSONEncoder().encode(RemapAction.dpiCycle)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"dpiCycle":{}}"#)
        XCTAssertEqual(try JSONDecoder().decode(RemapAction.self, from: encoded), .dpiCycle)
        let withDpiCycle = RemapAction.gesture(.defaults(click: .dpiCycle))
        XCTAssertEqual(try JSONDecoder().decode(RemapAction.self, from: JSONEncoder().encode(withDpiCycle)), withDpiCycle)
        XCTAssertEqual(RemapAction.dpiCycle.label, "DPI Cycle")
        XCTAssertFalse(RemapAction.dpiCycle.isGesture)
    }

    // MARK: What the page says

    /// The status line: what is missing first, then where driver mode stands, its error as it
    /// came. A missing Input Monitoring says plainly to turn it on in System Settings and then
    /// reopen MacRazer, as a grant made while it runs takes effect only then; a grant macOS
    /// hasn't applied to this run says to quit and reopen. Accessibility asks for no reopen.
    func testTheStatusLineSaysWhatIsMissingThenWhereDriverModeStands() {
        func status(_ mode: DpiDriverModeState, need: DpiDriverModeNeed = .ready, paused: Bool = false) -> String {
            ButtonRemapper.dpiPrivateKeyStatus(need: need, paused: paused, driverMode: mode)
        }
        XCTAssertEqual(status(.engaged, need: .accessibility), "MacRazer needs Accessibility to carry out this action.")
        XCTAssertEqual(status(.off, need: .inputMonitoring),
                       "MacRazer needs Input Monitoring to see the DPI button. Turn it on in System Settings, "
                       + "then reopen MacRazer.")
        XCTAssertEqual(status(.off, need: .inputMonitoring, paused: true), status(.off, need: .inputMonitoring), "first")
        for need: DpiDriverModeNeed in [.inputMonitoring, .relaunch] {
            XCTAssertTrue(status(.off, need: need).contains("reopen MacRazer"), "\(need)")
        }
        XCTAssertFalse(status(.off, need: .accessibility).contains("reopen"))
        XCTAssertEqual(status(.off, need: .relaunch),
                       "Input Monitoring is on, but macOS hasn't applied it to MacRazer yet. Quit and reopen MacRazer.")
        XCTAssertEqual(status(.off, need: .relaunch, paused: true), status(.off, need: .relaunch), "first")
        XCTAssertEqual(status(.engaged, paused: true), "Waiting for mouse connection")
        XCTAssertEqual(status(.engaged), "Ready")
        XCTAssertEqual(status(.engaging), "Setting up the DPI button…")
        XCTAssertEqual(status(.off), "Setting up the DPI button…", "wanted, not yet started")
        XCTAssertEqual(status(.unavailable("The mouse didn't accept it.")), "The mouse didn't accept it.")
        let needs: [DpiDriverModeNeed] = [.ready, .accessibility, .inputMonitoring, .relaunch]
        for mode: DpiDriverModeState in [.engaged, .engaging, .off] {
            for text in needs.map({ status(mode, need: $0) }) {
                XCTAssertFalse(text.contains("\u{2014}"), text)
                XCTAssertFalse(text.contains("relaunch"), text)
            }
        }
    }

    /// The editor and the help say how the gesture is made on this mouse, Click and Hold
    /// apart, and the help that the mouse is switched to a mode where MacRazer handles the
    /// button while it runs, and back when it quits or DPI Cycle (default) is chosen. A side
    /// button's editor says nothing of Hold, which it doesn't have.
    func testTheTextSaysHowTheGestureIsMadeAndHowTheMouseIsTakenOver() {
        let editor = RemapView.gestureEditorExplanation(longPress: true, followsPointer: false)
        XCTAssertEqual(editor, "Hold the DPI button until the gesture starts (about a second), then move the mouse up, "
                       + "down, left or right. A short press does Click. Holding it without moving does Hold "
                       + "when you let go. " + RemapView.dpiButtonTimingNote)
        // Said where the button is set up: the mouse reports it late, and which buttons don't.
        XCTAssertTrue(RemapView.dpiButtonTimingNote.contains("about a second into a hold"))
        XCTAssertTrue(RemapView.dpiButtonTimingNote.contains("side button or the wheel click"))
        XCTAssertFalse(RemapView.gestureEditorExplanation(longPress: false, followsPointer: false)
            .contains(RemapView.dpiButtonTimingNote), "a side button reports at once, so the note isn't its")
        XCTAssertFalse(RemapView.gestureEditorExplanation(longPress: false, followsPointer: false).contains("does Hold"))
        let help = RemapView.dpiButtonHelpText(privateKeys: true)
        XCTAssertTrue(help.contains("the mouse is switched to a mode where MacRazer handles the DPI button while it runs."))
        XCTAssertTrue(help.contains("It goes back to normal when MacRazer quits or DPI Cycle (default) is chosen."))
        XCTAssertTrue(help.contains("Hold the DPI button until the gesture starts (about a second)"))
        XCTAssertFalse(help.contains("F20"), "F20 is the Basilisk's")
        for text in [editor, help, RemapView.gestureEditorExplanation(longPress: true, followsPointer: true)] {
            XCTAssertFalse(text.contains("\u{2014}"), "no em dash")
        }
    }
}

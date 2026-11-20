// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import XCTest
@testable import MacRazer

/// The flags stored with a shortcut a button sends. macOS matches its own shortcuts on them.
final class ShortcutFlagsTests: XCTestCase {
    func testTheArrowPresetsAreStoredWithTheFlagsMacOSMatchesOn() {
        // Mission Control and the Space shortcuts are stored by macOS as Control + Fn (0x840000).
        let arrows = ButtonRemapper.presets.filter { (123...126).contains($0.keyCode) }
        XCTAssertEqual(arrows.map(\.id), ["missionControl", "spaceLeft", "spaceRight"])
        for preset in arrows {
            XCTAssertEqual(preset.flags, [.maskControl, .maskSecondaryFn, .maskNumericPad], preset.name)
            XCTAssertEqual(preset.action, .keystroke(keyCode: preset.keyCode, modifiers: preset.flags.rawValue,
                                                     name: preset.name))
        }
    }

    func testOtherPresetsCarryNoFnFlag() {
        for preset in ButtonRemapper.presets where !(123...126).contains(preset.keyCode) {
            XCTAssertFalse(preset.flags.contains(.maskSecondaryFn), preset.name)
        }
    }

    func testARecordedArrowOrFunctionKeyKeepsItsFnFlag() {
        XCTAssertEqual(RecorderNSView.storedFlags([.control, .function, .numericPad]),
                       [.maskControl, .maskSecondaryFn, .maskNumericPad], "⌃↑")
        XCTAssertEqual(RecorderNSView.storedFlags([.function]), .maskSecondaryFn, "F11")
        XCTAssertEqual(RecorderNSView.storedFlags([.command, .shift]), [.maskCommand, .maskShift], "⇧⌘4")
        XCTAssertEqual(RecorderNSView.storedFlags([.option, .capsLock]), .maskAlternate, "Caps Lock is not stored")
        XCTAssertTrue(RecorderNSView.storedFlags([]).isEmpty, "a bare Escape still cancels")
    }

    func testASavedArrowWithoutFnGoesOutWithIt() {
        // A button set to Mission Control before #143 holds Control alone.
        XCTAssertEqual(ButtonRemapper.postedFlags(keyCode: 126, saved: .maskControl),
                       [.maskControl, .maskSecondaryFn, .maskNumericPad], "⌃↑")
        XCTAssertEqual(ButtonRemapper.postedFlags(keyCode: 125, saved: .maskControl),
                       [.maskControl, .maskSecondaryFn, .maskNumericPad], "⌃↓ recorded by hand")
        XCTAssertEqual(ButtonRemapper.postedFlags(keyCode: 123, saved: .maskCommand),
                       [.maskCommand, .maskSecondaryFn, .maskNumericPad], "⌘←")
    }

    func testFlagsAlreadySavedAreLeftAsTheyAre() {
        for preset in ButtonRemapper.presets {
            XCTAssertEqual(ButtonRemapper.postedFlags(keyCode: preset.keyCode, saved: preset.flags), preset.flags,
                           preset.name)
        }
    }

    func testFunctionAndNavigationKeysGetFnOnly() {
        XCTAssertEqual(ButtonRemapper.postedFlags(keyCode: 103, saved: []), .maskSecondaryFn, "F11")
        XCTAssertEqual(ButtonRemapper.postedFlags(keyCode: 115, saved: .maskCommand),
                       [.maskCommand, .maskSecondaryFn], "⌘Home")
    }

    func testOtherKeysAreSentAsSaved() {
        XCTAssertEqual(ButtonRemapper.postedFlags(keyCode: 13, saved: .maskCommand), .maskCommand, "⌘W")
        XCTAssertEqual(ButtonRemapper.postedFlags(keyCode: 48, saved: .maskCommand), .maskCommand, "⌘Tab")
        XCTAssertEqual(ButtonRemapper.postedFlags(keyCode: 21, saved: [.maskCommand, .maskShift]),
                       [.maskCommand, .maskShift], "⇧⌘4")
    }

    func testASavedKeypadKeyGetsNumericPad() {
        XCTAssertEqual(ButtonRemapper.postedFlags(keyCode: 83, saved: .maskControl),
                       [.maskControl, .maskNumericPad], "⌃ keypad 1")
    }

    func testThePostedEventsCarryTheAddedFlags() {
        // What `apply` posts for a Mission Control button saved before #143.
        let events = ButtonRemapper.keystrokeEvents(keyCode: 126, saved: .maskControl, source: nil)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        for event in events {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 126)
            XCTAssertTrue(event.flags.isSuperset(of: [.maskControl, .maskSecondaryFn, .maskNumericPad]))
        }
    }
}

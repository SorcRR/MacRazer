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
}

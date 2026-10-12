// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import XCTest
@testable import MacRazer

final class DPIShortcutModifiersTests: XCTestCase {
    func testMapsCombinedModifiersToHIDBits() {
        let flags: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]
        XCTAssertEqual(DPIShortcutModifiers.hidValue(from: flags), 0x0f)
    }

    func testNoModifiersMapToZero() {
        XCTAssertEqual(DPIShortcutModifiers.hidValue(from: []), 0)
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class DPIStageAccentTests: XCTestCase {
    func testStageAccentOrderMatchesDPIStagePalette() {
        XCTAssertEqual((0..<5).map { DPIStageAccent.forStage(at: $0).name },
                       ["Red", "Green", "Blue", "Teal", "Yellow"])
    }

    func testStageAccessibilityLabelIncludesValueColorAndActiveState() {
        XCTAssertEqual(DPIStageAccent.accessibilityLabel(value: 1600, stageIndex: 2, active: true),
                       "1600 DPI, stage 3, Blue, active")
        XCTAssertEqual(DPIStageAccent.accessibilityLabel(value: 800, stageIndex: 1, active: false),
                       "800 DPI, stage 2, Green")
    }
}

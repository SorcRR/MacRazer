// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class DPIStageAccentTests: XCTestCase {
    func testStageAccentOrderRepeatsPastFiveStages() {
        XCTAssertEqual((0..<6).map { DPIStageAccent.forStage(at: $0).name },
                       ["Red", "Green", "Blue", "Cyan", "Yellow", "Red"])
    }

    func testStageAccessibilityLabelIncludesValueStageAndColor() {
        XCTAssertEqual(DPIStageAccent.accessibilityLabel(value: 1600, stageIndex: 2),
                       "1600 DPI, stage 3, Blue")
        XCTAssertEqual(DPIStageAccent.accessibilityLabel(value: 800, stageIndex: 1),
                       "800 DPI, stage 2, Green")
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazerHoliday

final class HolidayGameRulesTests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(HolidayGameRules.level(for: 0), 0)
        XCTAssertEqual(HolidayGameRules.level(for: 9), 0)
        XCTAssertEqual(HolidayGameRules.level(for: 10), 1)
        XCTAssertEqual(HolidayGameRules.level(for: 149), 4)
        XCTAssertEqual(HolidayGameRules.level(for: 200), 6)
        XCTAssertEqual(HolidayGameRules.level(for: 5000), 6)
        XCTAssertEqual(HolidayGameRules.pointsToNextLevel(from: 24), 1)
        XCTAssertNil(HolidayGameRules.pointsToNextLevel(from: 201))
        XCTAssertEqual(HolidayGameRules.progress(for: 75), 0.5, accuracy: 0.001)
    }

    func testVisibleTimes() {
        XCTAssertEqual(HolidayGameRules.visible(.santa, level: 0, warmingUpFrom: nil), 4)
        XCTAssertEqual(HolidayGameRules.visible(.santa, level: 6, warmingUpFrom: nil), 1.1)
        // The bonus is a second shorter, but never under the floor.
        XCTAssertEqual(HolidayGameRules.visible(.reindeer, level: 0, warmingUpFrom: nil), 3)
        XCTAssertEqual(HolidayGameRules.visible(.krampus, level: 6, warmingUpFrom: nil), 0.8)
        // Warming up: halfway between the old level and the new.
        XCTAssertEqual(HolidayGameRules.visible(.elf, level: 1, warmingUpFrom: 0), 3.6, accuracy: 0.001)
    }

    func testGaps() {
        XCTAssertEqual(HolidayGameRules.gap(score: 0, justCaught: false), 2...12)
        XCTAssertEqual(HolidayGameRules.gap(score: 3, justCaught: true), 2...3)
        XCTAssertEqual(HolidayGameRules.gap(score: 11, justCaught: false), 1...2)
    }

    func testPoints() {
        XCTAssertEqual(HolidayCharacter.santa.points, 1)
        XCTAssertEqual(HolidayCharacter.reindeer.points, 2)
        XCTAssertEqual(HolidayCharacter.elf.points, 1)
        XCTAssertEqual(HolidayCharacter.krampus.points, 3)
    }

    func testDaysKeptBuckets() {
        XCTAssertEqual(HolidayChange.offLater(afterDays: 0), .offLater0to1)
        XCTAssertEqual(HolidayChange.offLater(afterDays: 3), .offLater2to3)
        XCTAssertEqual(HolidayChange.offLater(afterDays: 7), .offLater4to7)
        XCTAssertEqual(HolidayChange.offLater(afterDays: 14), .offLater8to14)
        XCTAssertEqual(HolidayChange.offLater(afterDays: 30), .offLater15plus)
    }
}

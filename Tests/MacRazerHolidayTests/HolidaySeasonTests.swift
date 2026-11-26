// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazerHoliday

final class HolidaySeasonTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, in cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testPhasesAcrossTheSeason() {
        let cal = calendar("Europe/Budapest")
        XCTAssertNil(HolidaySeason.phase(of: date(2026, 11, 30, in: cal), calendar: cal))
        XCTAssertEqual(HolidaySeason.phase(of: date(2026, 12, 1, 0, in: cal), calendar: cal), .advent)
        XCTAssertEqual(HolidaySeason.phase(of: date(2026, 12, 23, in: cal), calendar: cal), .advent)
        XCTAssertEqual(HolidaySeason.phase(of: date(2026, 12, 24, in: cal), calendar: cal), .christmasEve)
        XCTAssertEqual(HolidaySeason.phase(of: date(2026, 12, 25, in: cal), calendar: cal), .christmasDay)
        XCTAssertEqual(HolidaySeason.phase(of: date(2026, 12, 31, in: cal), calendar: cal), .afterChristmas)
        XCTAssertEqual(HolidaySeason.phase(of: date(2027, 1, 1, in: cal), calendar: cal), .newYearsDay)
        XCTAssertEqual(HolidaySeason.phase(of: date(2027, 1, 5, in: cal), calendar: cal), .windDown)
        XCTAssertEqual(HolidaySeason.phase(of: date(2027, 1, 6, 23, in: cal), calendar: cal), .lastDay)
        XCTAssertNil(HolidaySeason.phase(of: date(2027, 1, 7, 0, in: cal), calendar: cal))
    }

    func testTheSameMomentIsTheLocalDayInEachZone() {
        // 23:30 UTC on Nov 30 is already Dec 1 in Tokyo, still Nov 30 in Los Angeles.
        let utc = calendar("UTC")
        let moment = utc.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 23, minute: 30))!
        XCTAssertEqual(HolidaySeason.phase(of: moment, calendar: calendar("Asia/Tokyo")), .advent)
        XCTAssertNil(HolidaySeason.phase(of: moment, calendar: calendar("America/Los_Angeles")))
    }

    func testJanuaryBelongsToTheDecemberSeason() {
        let cal = calendar("UTC")
        XCTAssertEqual(HolidaySeason.year(of: date(2026, 12, 3, in: cal), calendar: cal), 2026)
        XCTAssertEqual(HolidaySeason.year(of: date(2027, 1, 4, in: cal), calendar: cal), 2026)
        XCTAssertEqual(HolidaySeason.year(of: date(2027, 12, 3, in: cal), calendar: cal), 2027)
        XCTAssertNil(HolidaySeason.year(of: date(2027, 6, 1, in: cal), calendar: cal))
    }

    func testSleepsUntilChristmas() {
        let cal = calendar("UTC")
        XCTAssertEqual(HolidaySeason.sleepsUntilChristmas(from: date(2026, 12, 1, in: cal), calendar: cal), 24)
        XCTAssertEqual(HolidaySeason.sleepsUntilChristmas(from: date(2026, 12, 24, 23, in: cal), calendar: cal), 1)
        XCTAssertNil(HolidaySeason.sleepsUntilChristmas(from: date(2026, 12, 25, in: cal), calendar: cal))
    }

    func testStarGoesUpOnChristmasDay() {
        XCTAssertFalse(HolidayPhase.advent.hasStar)
        XCTAssertFalse(HolidayPhase.christmasEve.hasStar)
        XCTAssertTrue(HolidayPhase.christmasDay.hasStar)
        XCTAssertTrue(HolidayPhase.lastDay.hasStar)
    }

    func testTheSeasonIsGregorianWhateverTheMacsCalendar() {
        XCTAssertEqual(HolidaySeason.calendar.identifier, .gregorian)
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "UTC")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let christmas = utc.date(from: DateComponents(year: 2026, month: 12, day: 25, hour: 12))!
        // On the Buddhist calendar the same day is in 2569: the season must still be 2026.
        XCTAssertEqual(buddhist.component(.year, from: christmas), 2569)
        XCTAssertEqual(HolidaySeason.year(of: christmas), 2026)
        XCTAssertEqual(HolidaySeason.phase(of: christmas), .christmasDay)
    }
}

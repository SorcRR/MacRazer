// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazerHoliday

@MainActor
final class HolidayPresentsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var clock = Date()
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "HolidayPresentsTests.\(UUID().uuidString)")
        at(2026, 12, 25)
    }

    private func at(_ y: Int, _ m: Int, _ d: Int) {
        clock = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func holiday() -> Holiday {
        Holiday(defaults: defaults, calendar: calendar, now: { [unowned self] in clock },
                watchSystem: false, stillness: { false })
    }

    func testStagesByDay() {
        XCTAssertNil(HolidaySeason.presentsStage(of: date(12, 23), calendar: calendar))
        XCTAssertEqual(HolidaySeason.presentsStage(of: date(12, 24), calendar: calendar), .waiting)
        XCTAssertEqual(HolidaySeason.presentsStage(of: date(12, 25), calendar: calendar), .open)
        XCTAssertEqual(HolidaySeason.presentsStage(of: date(12, 26), calendar: calendar), .open)
        XCTAssertNil(HolidaySeason.presentsStage(of: date(12, 27), calendar: calendar), "Gone from the 27th")
    }

    private func date(_ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))!
    }

    func testNoPresentsWithTheDecorationsOff() {
        let h = holiday()
        h.setDecorations(on: false)
        XCTAssertNil(h.presentsStage)
    }

    func testThreeDifferentGiftsWhateverTheRolls() {
        // Every roll a golden chocolate: still three different gifts.
        XCTAssertEqual(Set(HolidayGift.pickThree(random: { 0.001 })).count, 3)
        XCTAssertEqual(Set(HolidayGift.pickThree(random: { 0.03 })).count, 3)
        XCTAssertEqual(Set(HolidayGift.pickThree(random: { 0.999 })).count, 3)
        var seeded = SeededRandom(seed: 5)
        for _ in 0..<500 {
            XCTAssertEqual(Set(HolidayGift.pickThree(random: { seeded.next() })).count, 3)
        }
    }

    func testRareGiftsAreRoughlyAsRareAsPlanned() {
        var seeded = SeededRandom(seed: 9)
        var mouse = 0, chocolate = 0
        let players = 20_000
        for _ in 0..<players {
            let gifts = HolidayGift.pickThree(random: { seeded.next() })
            if gifts.contains(.goldenMouse) { mouse += 1 }
            if gifts.contains(.goldenChocolate) { chocolate += 1 }
        }
        // About 14% of players get a golden mouse and 3% golden chocolate.
        XCTAssertEqual(Double(mouse) / Double(players), 0.14, accuracy: 0.02)
        XCTAssertEqual(Double(chocolate) / Double(players), 0.03, accuracy: 0.01)
    }

    func testOpeningKeepsTheSameGiftsForTheSeason() {
        let h = holiday()
        let presents = HolidayPresents(holiday: h)
        let first = presents.open(1)
        XCTAssertNotNil(first)
        XCTAssertEqual(presents.opened, [1])
        XCTAssertEqual(presents.featured, 1)
        XCTAssertNil(presents.open(1), "Already open")
        // The next day, after a relaunch: the same three, box 1 still open.
        at(2026, 12, 26)
        let again = HolidayPresents(holiday: holiday())
        XCTAssertEqual(again.gift(in: 1), first)
        XCTAssertEqual(again.opened, [1])
        again.open(0); again.open(2)
        XCTAssertTrue(again.allOpened)
        XCTAssertEqual(Set(again.gifts).count, 3)
    }

    func testChristmasEveCanNotBeOpened() {
        at(2026, 12, 24)
        let presents = HolidayPresents(holiday: holiday())
        XCTAssertEqual(presents.stage, .waiting)
        XCTAssertNil(presents.open(0))
        XCTAssertTrue(presents.opened.isEmpty)
    }

    func testHidingIsRememberedAndCountedOnce() {
        let h = holiday()
        h.keep()
        h.changesSent(h.pendingChanges)
        let presents = HolidayPresents(holiday: h)
        presents.setHidden(true)
        presents.setHidden(false)
        presents.setHidden(true)
        XCTAssertEqual(h.pendingChanges, [.presentsHidden])
        XCTAssertTrue(HolidayPresents(holiday: holiday()).hidden)
    }

    func testANewSeasonStartsWithNewPresents() {
        let h = holiday()
        let presents = HolidayPresents(holiday: h)
        presents.open(0)
        at(2027, 12, 25)
        h.refresh()
        XCTAssertTrue(presents.opened.isEmpty)
        XCTAssertTrue(presents.gifts.isEmpty)
    }

    func testChristmasEveLine() {
        at(2026, 12, 24)
        XCTAssertEqual(holiday().headline, "Christmas Eve. Presents arrive tomorrow")
    }
}

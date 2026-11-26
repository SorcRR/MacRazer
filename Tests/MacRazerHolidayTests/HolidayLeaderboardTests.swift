// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazerHoliday

@MainActor
final class HolidayLeaderboardTests: XCTestCase {
    private var defaults: UserDefaults!
    private var clock = Date()
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "HolidayLeaderboardTests.\(UUID().uuidString)")
        at(2027, 1, 1)
    }

    private func at(_ y: Int, _ m: Int, _ d: Int) {
        clock = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func holiday() -> Holiday {
        Holiday(defaults: defaults, calendar: calendar, now: { [unowned self] in clock },
                watchSystem: false, stillness: { false })
    }

    private func leaderboard(_ h: Holiday, players: Int? = 128) -> HolidayLeaderboard {
        HolidayLeaderboard(holiday: h, game: HolidayGame(holiday: h), presents: HolidayPresents(holiday: h),
                           source: players.map { HolidayMockBoard(players: $0) })
    }

    func testNamesAreCleanedOrRefused() {
        XCTAssertEqual(HolidayLeaderboard.cleaned("  Frosty   Gingerbread "), "Frosty Gingerbread")
        XCTAssertEqual(HolidayLeaderboard.cleaned("Rudolph's Fan-Club 2"), "Rudolph's Fan-Club 2")
        XCTAssertNil(HolidayLeaderboard.cleaned("ab"), "Too short")
        XCTAssertNil(HolidayLeaderboard.cleaned(String(repeating: "x", count: 25)), "Too long")
        XCTAssertNil(HolidayLeaderboard.cleaned("<script>"))
        XCTAssertNil(HolidayLeaderboard.cleaned("https://spam.example"))
    }

    func testNotThereWithoutASourceOrOutOfSeason() {
        XCTAssertFalse(leaderboard(holiday(), players: nil).isAvailable)
        at(2027, 2, 1)
        let off = leaderboard(holiday())
        XCTAssertFalse(off.isAvailable)
        XCTAssertFalse(off.join(as: "Frosty Gingerbread"))
    }

    func testJoiningIsRememberedAndLeavingForgetsIt() {
        let h = holiday()
        let board = leaderboard(h)
        XCTAssertFalse(board.joined)
        XCTAssertFalse(board.join(as: "x"), "A name that isn't fit to show")
        XCTAssertTrue(board.join(as: "Jolly Sprout"))
        XCTAssertEqual(leaderboard(holiday()).name, "Jolly Sprout")
        board.leave()
        XCTAssertNil(leaderboard(holiday()).name)
    }

    func testYourRowIsSlottedInWithAGapBelowTheTopTen() throws {
        let board = leaderboard(holiday())
        board.join(as: "Jolly Sprout")
        board.refresh()
        XCTAssertTrue(board.isOpen)
        XCTAssertEqual(board.board?.playerCount, 129)
        let rows = board.visibleRows
        XCTAssertEqual(rows.count, HolidayLeaderboard.topRows + 1)
        let last = try XCTUnwrap(rows.last)
        XCTAssertTrue(last.player.isYou)
        XCTAssertTrue(last.gapAbove)
        XCTAssertEqual(last.rank, board.rank)
        XCTAssertEqual(rows.map(\.rank).prefix(10), Array(1...10)[...])
    }

    func testBelowThirtyNobodySeesAnyNames() {
        let board = leaderboard(holiday(), players: 17)
        board.join(as: "Jolly Sprout")
        board.refresh()
        XCTAssertFalse(board.isOpen)
        XCTAssertEqual(board.board?.playerCount, 18)
        XCTAssertTrue(board.board?.players.isEmpty ?? false)
        XCTAssertNil(board.rank)
        XCTAssertTrue(board.visibleRows.isEmpty)
    }

    func testANewSeasonStartsUnjoined() {
        let h = holiday()
        let board = leaderboard(h)
        board.join(as: "Jolly Sprout")
        at(2027, 12, 1)
        h.refresh()
        XCTAssertNil(board.name)
    }

    func testGiftsShowRarestFirst() {
        let player = HolidayPlayer(id: "a", name: "A", score: 1, counts: [:],
                                   gifts: [.socks, .goldenChocolate, .goldenMouse], isYou: false)
        XCTAssertEqual(player.giftsRarestFirst, [.goldenChocolate, .goldenMouse, .socks])
    }
}

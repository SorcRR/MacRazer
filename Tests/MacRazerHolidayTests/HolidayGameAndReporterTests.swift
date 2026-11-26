// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazerHoliday

@MainActor
final class HolidayGameAndReporterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var clock = Date()
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "HolidayGameTests.\(UUID().uuidString)")
        clock = calendar.date(from: DateComponents(year: 2026, month: 12, day: 10, hour: 12))!
    }

    private func holiday() -> Holiday {
        Holiday(defaults: defaults, calendar: calendar, now: { [unowned self] in clock }, watchSystem: false, stillness: { false })
    }

    func testCatchingScoresAndPersistsPerSeason() {
        let h = holiday()
        let game = HolidayGame(holiday: h)
        let spot = UUID()
        game.register(spot, surface: .popover)
        XCTAssertTrue(game.caught(game.forcePeek(.santa, spot: spot).id))
        XCTAssertTrue(game.caught(game.forcePeek(.reindeer, spot: spot).id))
        XCTAssertEqual(game.score, 3)
        XCTAssertEqual(game.counts[.reindeer], 1)
        XCTAssertNotNil(game.bubble)
        XCTAssertEqual(h.pendingChanges, [.played], "The first catch is counted once")
        // A new game on the same storage picks the score up again.
        XCTAssertEqual(HolidayGame(holiday: h).score, 3)
    }

    func testAPeekThatLeftCanNotBeCaught() {
        let game = HolidayGame(holiday: holiday())
        let spot = UUID()
        game.register(spot, surface: .settings)
        let old = game.forcePeek(.elf, spot: spot)
        _ = game.forcePeek(.krampus, spot: spot)
        XCTAssertFalse(game.caught(old.id))
        XCTAssertEqual(game.score, 0)
    }

    func testUnregisteringACardRemovesItsPeek() {
        let game = HolidayGame(holiday: holiday())
        let spot = UUID()
        game.register(spot, surface: .popover)
        _ = game.forcePeek(.santa, spot: spot)
        game.unregister(spot)
        XCTAssertNil(game.peek)
    }

    func testReporterURLAndReply() async throws {
        let h = holiday()
        h.keep()
        let reporter = HolidayReporter(holiday: h)
        var asked: [URL] = []
        reporter.configure(base: URL(string: "https://reports.example")!, appVersion: "0.11.0") { url in
            asked.append(url)
            let reply = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"enabled":false}"#.utf8), reply)
        }
        await reporter.reportIfNeeded()
        let url = try XCTUnwrap(asked.first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.path, "/v1/holiday")
        XCTAssertEqual(items.first { $0.name == "season" }?.value, "2026")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "on")
        XCTAssertEqual(items.first { $0.name == "changes" }?.value, "kept")
        XCTAssertNil(items.first { $0.name == "id" }, "Anonymous: no ID for the Mac")
        XCTAssertEqual(h.pendingChanges, [])
        XCTAssertFalse(h.isFestive, "The reply switched the decorations off")
        // Nothing new the same day: no second request.
        await reporter.reportIfNeeded()
        XCTAssertEqual(asked.count, 1)
    }

    func testReporterKeepsChangesWhenTheSendFails() async {
        let h = holiday()
        h.keep()
        let reporter = HolidayReporter(holiday: h)
        reporter.configure(base: URL(string: "https://reports.example")!, appVersion: nil) { _ in throw URLError(.notConnectedToInternet) }
        await reporter.reportIfNeeded()
        XCTAssertEqual(h.pendingChanges, [.kept])
        XCTAssertTrue(h.isFestive)
    }

    func testReporterSendsNothingOffSeason() async {
        clock = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let reporter = HolidayReporter(holiday: holiday())
        var asked = 0
        reporter.configure(base: URL(string: "https://reports.example")!, appVersion: nil) { url in
            asked += 1
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await reporter.reportIfNeeded()
        XCTAssertEqual(asked, 0)
    }

    func testReporterBacksOffAfterAFailedReply() async {
        let h = holiday()
        h.keep()
        let reporter = HolidayReporter(holiday: h)
        var asked = 0
        reporter.configure(base: URL(string: "https://reports.example")!, appVersion: nil) { url in
            asked += 1
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        await reporter.reportIfNeeded()
        clock = clock.addingTimeInterval(15 * 60)
        await reporter.reportIfNeeded()
        XCTAssertEqual(asked, 1, "No retry on the next 15-minute tick")
        clock = clock.addingTimeInterval(50 * 60)
        await reporter.reportIfNeeded()
        XCTAssertEqual(asked, 2, "Tried again after an hour")
        XCTAssertEqual(HolidayReporter.backoff(afterFailures: 2), 7200)
        XCTAssertEqual(HolidayReporter.backoff(afterFailures: 9), 24 * 3600)
    }

    func testLastDayChangesGoOutAfterTheSeason() async throws {
        clock = calendar.date(from: DateComponents(year: 2027, month: 1, day: 6, hour: 22))!
        let h = holiday()
        h.keep()
        clock = calendar.date(from: DateComponents(year: 2027, month: 1, day: 8, hour: 9))!
        h.refresh()
        XCTAssertFalse(h.isFestive)
        let reporter = HolidayReporter(holiday: h)
        var asked: [URL] = []
        reporter.configure(base: URL(string: "https://reports.example")!, appVersion: nil) { url in
            asked.append(url)
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await reporter.reportIfNeeded()
        let items = URLComponents(url: try XCTUnwrap(asked.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "season" }?.value, "2026")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "ended")
        XCTAssertEqual(items.first { $0.name == "changes" }?.value, "kept")
        XCTAssertEqual(h.pendingChanges, [])
        // Nothing left to send: no daily count after the season.
        clock = clock.addingTimeInterval(86400)
        await reporter.reportIfNeeded()
        XCTAssertEqual(asked.count, 1)
    }

    func testSwitchingDecorationsStopsAndRestartsTheGame() async {
        let h = holiday()
        h.keep()
        let game = HolidayGame(holiday: h)
        game.setVisible(.popover, true)
        XCTAssertTrue(game.watchingClicks)
        h.setDecorations(on: false)
        await Task.yield(); try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(game.watchingClicks, "Nothing watches clicks with the decorations off")
        h.setDecorations(on: true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(game.watchingClicks)
        game.setVisible(.popover, false)
    }

    func testNoClickMonitorOffSeason() {
        clock = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 12))!
        let game = HolidayGame(holiday: holiday())
        game.setVisible(.popover, true)
        XCTAssertFalse(game.watchingClicks)
        game.setVisible(.popover, false)
    }

    func testScoreReloadsWhenTheSeasonChanges() {
        let h = holiday()
        let game = HolidayGame(holiday: h)
        let spot = UUID()
        game.register(spot, surface: .popover)
        game.caught(game.forcePeek(.santa, spot: spot).id)
        XCTAssertEqual(game.score, 1)
        clock = calendar.date(from: DateComponents(year: 2027, month: 12, day: 2, hour: 12))!
        h.refresh()
        XCTAssertEqual(game.score, 0, "A new season starts at zero")
    }

    func testOneCharacterAtATimeAcrossThePopoverAndSettings() {
        let game = HolidayGame(holiday: holiday())
        let card = UUID(), group = UUID()
        game.register(card, surface: .popover)
        game.register(group, surface: .settings)
        XCTAssertEqual(game.eligibleSpot(on: .settings), group)
        let santa = game.forcePeek(.santa, spot: card)
        XCTAssertNil(game.eligibleSpot(on: .settings), "Settings waits while Santa is out in the popover")
        XCTAssertTrue(game.caught(santa.id))
        XCTAssertEqual(game.eligibleSpot(on: .settings), group)
    }
}

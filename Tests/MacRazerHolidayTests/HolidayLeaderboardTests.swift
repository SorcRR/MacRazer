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

    private struct Parts {
        let holiday: Holiday
        let game: HolidayGame
        let presents: HolidayPresents
        let board: HolidayLeaderboard
    }

    private func make(_ source: HolidayBoardSource? = HolidayMockBoard(players: 128), holiday h: Holiday? = nil) -> Parts {
        let h = h ?? holiday()
        let game = HolidayGame(holiday: h)
        let presents = HolidayPresents(holiday: h)
        return Parts(holiday: h, game: game, presents: presents,
                     board: HolidayLeaderboard(holiday: h, game: game, presents: presents, source: source))
    }

    // MARK: Names and availability

    func testNamesAreCleanedOrRefused() {
        XCTAssertEqual(HolidayLeaderboard.cleaned("  Frosty   Gingerbread "), "Frosty Gingerbread")
        XCTAssertEqual(HolidayLeaderboard.cleaned("Rudolph's Fan-Club 2"), "Rudolph's Fan-Club 2")
        XCTAssertNil(HolidayLeaderboard.cleaned("ab"), "Too short")
        XCTAssertNil(HolidayLeaderboard.cleaned(String(repeating: "x", count: 25)), "Too long")
        XCTAssertNil(HolidayLeaderboard.cleaned("<script>"))
        XCTAssertNil(HolidayLeaderboard.cleaned("https://spam.example"))
    }

    func testNotThereWithoutASourceOrOutOfSeason() async {
        XCTAssertFalse(make(nil).board.isAvailable)
        at(2027, 2, 1)
        let off = make().board
        XCTAssertFalse(off.isAvailable)
        let joined = await off.join(as: "Frosty Gingerbread")
        XCTAssertFalse(joined)
    }

    func testConfigureUsesTheWorkerOnlyWithAUUID() {
        let parts = make(nil)
        parts.board.configure(base: URL(string: "https://reports.example"), hardwareUUID: nil, send: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertFalse(parts.board.isAvailable)
        parts.board.configure(base: URL(string: "https://reports.example"), hardwareUUID: "ABC", send: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertTrue(parts.board.isAvailable)
    }

    // MARK: Joining and leaving

    func testJoiningIsRememberedAndLeavingForgetsIt() async {
        let source = FakeSource()
        let parts = make(source)
        let refused = await parts.board.join(as: "x")
        XCTAssertFalse(refused, "A name that isn't fit to show never goes out")
        XCTAssertTrue(source.calls.isEmpty)
        let joined = await parts.board.join(as: "Jolly Sprout")
        XCTAssertTrue(joined)
        XCTAssertEqual(make(source, holiday: holiday()).board.name, "Jolly Sprout")
        parts.board.leave()
        XCTAssertNil(parts.board.name)
        await parts.board.sync()
        XCTAssertTrue(source.calls.contains("leave"))
        XCTAssertNil(make(source, holiday: holiday()).board.name)
    }

    func testLeavingFetchesTheBoardAgain() async {
        let source = FakeSource()
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        XCTAssertNotNil(parts.board.board)
        parts.board.leave()
        XCTAssertNil(parts.board.board, "The page shows Loading, not an empty board")
        for _ in 0..<100 where parts.board.board == nil { await Task.yield() }
        XCTAssertNotNil(parts.board.board, "The board comes back without you")
        XCTAssertTrue(source.calls.contains("leave"))
    }

    func testTheWorkersNameWinsAndARefusedNameSaysWhy() async {
        let source = FakeSource()
        source.joinName = "Merry Robin"
        let parts = make(source)
        await parts.board.join(as: "Rude Name Here")
        XCTAssertEqual(parts.board.name, "Merry Robin", "Renamed by the admin")
        source.joinError = .badName
        let again = await parts.board.join(as: "Another Rude One")
        XCTAssertFalse(again)
        XCTAssertEqual(parts.board.problem, "That name isn't allowed. Try another one.")
    }

    func testLeavingStaysPossibleAfterTheSeasonAndWhenSwitchedOff() async {
        let parts = make(FakeSource())
        await parts.board.join(as: "Jolly Sprout")
        parts.holiday.setRemoteAllowed(false)
        XCTAssertFalse(parts.board.isAvailable)
        XCTAssertTrue(parts.board.canLeave, "Switched off for everyone: the row can still go")
        parts.holiday.setRemoteAllowed(true)
        at(2027, 1, 20)
        parts.holiday.refresh()
        XCTAssertTrue(parts.board.canLeave, "The board stands until the 25th")
        at(2027, 2, 2)
        parts.holiday.refresh()
        XCTAssertFalse(parts.board.canLeave)
    }

    func testALeaveThatFailsIsTriedAgain() async {
        let source = FakeSource()
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        source.failing = true
        parts.board.leave()
        await parts.board.sync()
        source.failing = false
        await parts.board.sync()
        XCTAssertEqual(source.calls.filter { $0 == "leave" }.count, 2)
        await parts.board.sync()
        XCTAssertEqual(source.calls.filter { $0 == "leave" }.count, 2, "Once it went through, it's done")
    }

    func testRejoiningAfterAReinstallBringsTheCatchesBack() async {
        let source = FakeSource()
        source.stored = [.santa: 40, .krampus: 2]
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        XCTAssertEqual(parts.game.counts[.santa], 40)
        XCTAssertEqual(parts.game.score, 46)
        XCTAssertFalse(source.calls.contains("score"), "Nothing new to send: the Worker has it all")
    }

    func testAGrownScoreGoesOutOnlyWhenItChanged() async {
        let source = FakeSource()
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        let spot = UUID()
        parts.game.register(spot, surface: .popover)
        parts.game.caught(parts.game.forcePeek(.reindeer, spot: spot).id)
        await parts.board.sync()
        XCTAssertEqual(source.sentCounts?[.reindeer], 1)
        let sent = source.calls.filter { $0 == "score" }.count
        await parts.board.sync()
        XCTAssertEqual(source.calls.filter { $0 == "score" }.count, sent)
    }

    func testAScoreTheWorkerDidntTakeGoesAgain() async {
        let source = FakeSource()
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        let spot = UUID()
        parts.game.register(spot, surface: .popover)
        parts.game.caught(parts.game.forcePeek(.santa, spot: spot).id)
        // Within five minutes of the last one: the Worker answers what it had.
        source.storesScores = false
        await parts.board.sync()
        source.storesScores = true
        await parts.board.sync()
        XCTAssertEqual(source.calls.filter { $0 == "score" }.count, 2)
        await parts.board.sync()
        XCTAssertEqual(source.calls.filter { $0 == "score" }.count, 2, "Stored now: nothing more to send")
    }

    func testTheScoreGoesEveryThreeHoursLikeTheUpdateCheck() async {
        let source = FakeSource()
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        XCTAssertFalse(parts.board.isDue, "Just sent with the join")
        XCTAssertFalse(parts.board.hasSomethingToSend)
        let spot = UUID()
        parts.game.register(spot, surface: .popover)
        parts.game.caught(parts.game.forcePeek(.santa, spot: spot).id)
        XCTAssertTrue(parts.board.hasSomethingToSend, "Quitting now would send it")
        clock = clock.addingTimeInterval(2 * 3600)
        XCTAssertFalse(parts.board.isDue)
        clock = clock.addingTimeInterval(3600)
        XCTAssertTrue(parts.board.isDue)
        // A send that doesn't get through leaves it due.
        source.scoreError = .unavailable
        await parts.board.sync()
        XCTAssertTrue(parts.board.isDue)
        source.scoreError = nil
        await parts.board.sync()
        XCTAssertFalse(parts.board.isDue)
        XCTAssertFalse(parts.board.hasSomethingToSend)
    }

    func testQuittingWaitsAtMostAMoment() async {
        let source = FakeSource()
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        let spot = UUID()
        parts.game.register(spot, surface: .popover)
        parts.game.caught(parts.game.forcePeek(.santa, spot: spot).id)
        source.slow = true
        let started = Date()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            parts.board.syncBeforeQuit(within: 0.2) { done.resume() }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(source.calls.last, "score", "It tried")
    }

    func testDeletedByTheAdminMeansNotJoined() async {
        let source = FakeSource()
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        let spot = UUID()
        parts.game.register(spot, surface: .popover)
        parts.game.caught(parts.game.forcePeek(.santa, spot: spot).id)
        source.scoreError = .notJoined
        await parts.board.sync()
        XCTAssertNil(parts.board.name)
    }

    // MARK: The board

    func testYourRowIsSlottedInWithAGapBelowTheTopTen() async throws {
        let parts = make()
        parts.board.previewJoin("Jolly Sprout")
        XCTAssertTrue(parts.board.hasPlayers)
        XCTAssertEqual(parts.board.board?.playerCount, 129)
        let rows = parts.board.visibleRows
        XCTAssertEqual(rows.count, HolidayLeaderboard.topRows + 1)
        let last = try XCTUnwrap(rows.last)
        XCTAssertTrue(last.player.isYou)
        XCTAssertTrue(last.gapAbove)
        XCTAssertEqual(last.rank, parts.board.rank)
        XCTAssertEqual(rows.map(\.rank).prefix(10), Array(1...10)[...])
    }

    func testYourRowShowsYourScoreNowAndMovesUp() async throws {
        let source = FakeSource()
        // You at 12 on the Worker, 11th; the tenth has 20.
        let others = (1...10).map { HolidayPlayer(id: "p\($0)", name: "P\($0)", score: 120 - $0 * 10, counts: [:], gifts: [], isYou: false) }
        source.board = HolidayBoard(playerCount: 40, top: others,
                                    you: HolidayPlayer(id: "me", name: "Jolly Sprout", score: 12, counts: [:], gifts: [], isYou: true),
                                    yourRank: 11)
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        await parts.board.refreshNow()
        XCTAssertEqual(parts.board.visibleRows.last?.player.score, 12, "Nothing caught on this Mac yet: the Worker's 12 stands")
        let spot = UUID()
        parts.game.register(spot, surface: .popover)
        for _ in 0..<25 { parts.game.caught(parts.game.forcePeek(.santa, spot: spot).id) }
        // The Worker places you by the score sent with the fetch: 25 is 10th, past the old tenth's 20.
        source.board?.yourRank = 10
        await parts.board.refreshNow()
        let rows = parts.board.visibleRows
        XCTAssertEqual(rows.count, 10, "In the top ten, the old tenth drops out")
        let me = try XCTUnwrap(rows.first { $0.player.isYou })
        XCTAssertEqual(me.player.score, 25, "Your score as it is on this Mac")
        XCTAssertEqual(me.rank, 10)
        XCTAssertFalse(rows.contains { $0.player.id == "p10" })
        XCTAssertEqual(source.boardScoreSent, 25)
    }

    func testNoConnectionIsSaid() async {
        let source = FakeSource()
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        source.boardFails = true
        await parts.board.refreshNow()
        XCTAssertTrue(parts.board.boardUnreachable)
        source.boardFails = false
        await parts.board.refreshNow()
        XCTAssertFalse(parts.board.boardUnreachable)
    }

    func testAFewPlayersShowFromTheFirst() {
        let parts = make(HolidayMockBoard(players: 4))
        parts.board.previewJoin("Jolly Sprout")
        XCTAssertTrue(parts.board.hasPlayers)
        XCTAssertEqual(parts.board.board?.playerCount, 5)
        XCTAssertEqual(parts.board.visibleRows.count, 5)
        XCTAssertNotNil(parts.board.rank)
        XCTAssertTrue(parts.board.visibleRows.contains { $0.player.isYou })
    }

    func testAnEmptyBoardHasNoRows() {
        let parts = make(HolidayMockBoard(players: 0))
        parts.board.previewBoard()
        XCTAssertFalse(parts.board.hasPlayers)
        XCTAssertEqual(parts.board.board?.playerCount, 0)
        XCTAssertTrue(parts.board.visibleRows.isEmpty)
    }

    func testANewSeasonStartsUnjoined() async {
        let parts = make(FakeSource())
        await parts.board.join(as: "Jolly Sprout")
        at(2027, 12, 1)
        parts.holiday.refresh()
        XCTAssertNil(parts.board.name)
    }

    func testGiftsShowRarestFirst() {
        let player = HolidayPlayer(id: "a", name: "A", score: 1, counts: [:],
                                   gifts: [.socks, .goldenChocolate, .goldenMouse], isYou: false)
        XCTAssertEqual(player.giftsRarestFirst, [.goldenChocolate, .goldenMouse, .socks])
    }

    // MARK: Presents

    func testTheWorkersPresentsAreTakenUntilABoxIsOpen() async {
        at(2026, 12, 25)
        let source = FakeSource()
        source.gifts = [.goldenMouse, .socks, .banana]
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        await parts.board.syncPresents()
        XCTAssertEqual(parts.presents.open(0), .goldenMouse)
        // A different pick later never changes a gift already shown.
        source.gifts = [.coal, .carrot, .mitten]
        await parts.board.syncPresents()
        XCTAssertEqual(parts.presents.gift(in: 0), .goldenMouse)
        XCTAssertEqual(source.openedSent, [0])
        // Nothing new: no request, however often it's asked.
        let asked = source.calls.filter { $0 == "presents" }.count
        await parts.board.syncPresents()
        await parts.board.sync()
        XCTAssertEqual(source.calls.filter { $0 == "presents" }.count, asked)
    }

    func testABoxOpenedOnTheMacsOwnPickStaysOffTheBoard() async {
        at(2026, 12, 25)
        let source = FakeSource()
        source.gifts = [.goldenMouse, .socks, .banana]
        source.presentsFail = true
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        // No connection when the box is opened: the Mac picks.
        let mine = parts.presents.open(0)
        XCTAssertNotNil(mine)
        source.presentsFail = false
        await parts.board.syncPresents()
        await parts.board.syncPresents()
        XCTAssertEqual(parts.presents.gift(in: 0), mine, "A gift shown never changes")
        if parts.presents.gifts != source.gifts {
            XCTAssertEqual(source.openedSent, [], "The Worker never hears of a box it didn't fill")
        }
        XCTAssertEqual(parts.board.you?.gifts, [mine!], "Your own row shows what you opened")
    }

    func testTheBoxesWaitForTheWorkersPicks() async {
        at(2026, 12, 25)
        let source = FakeSource()
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        // The join's own sync got no picks: fresh ones now, and a slow answer.
        source.gifts = [.goldenMouse, .socks, .banana]
        source.presentsDelay = 0.3
        let asking = Task { await parts.board.syncPresents() }
        try? await Task.sleep(for: .seconds(0.1))
        XCTAssertTrue(parts.presents.awaitingPicks)
        XCTAssertNil(parts.presents.open(0), "Not while the picks are on their way")
        await asking.value
        XCTAssertFalse(parts.presents.awaitingPicks)
        XCTAssertEqual(parts.presents.open(0), .goldenMouse)
        await parts.board.syncPresents()
        XCTAssertEqual(source.openedSent, [0])
    }

    func testTheBoxesStopWaitingAfterAFewSeconds() async {
        at(2026, 12, 25)
        let source = FakeSource()
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        source.gifts = [.goldenMouse, .socks, .banana]
        source.presentsDelay = HolidayLeaderboard.presentsHold + 1
        let asking = Task { await parts.board.syncPresents() }
        try? await Task.sleep(for: .seconds(HolidayLeaderboard.presentsHold + 0.3))
        XCTAssertFalse(parts.presents.awaitingPicks, "The boxes open on the Mac's own pick")
        asking.cancel()
        await asking.value
    }

    // MARK: Leaving and joining again

    func testJoiningAgainWaitsForTheLeave() async {
        let source = FakeSource()
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        source.leaveDelay = 0.3
        parts.board.leave()
        try? await Task.sleep(for: .seconds(0.05))
        let rejoined = await parts.board.join(as: "Merry Robin")
        XCTAssertTrue(rejoined)
        try? await Task.sleep(for: .seconds(0.5))
        let lastLeave = source.calls.lastIndex(of: "leave")!
        let lastJoin = source.calls.lastIndex(of: "join")!
        XCTAssertLessThan(lastLeave, lastJoin, "The leave can't delete the new row")
        XCTAssertEqual(source.calls.filter { $0 == "leave" }.count, 1)
        XCTAssertEqual(parts.board.name, "Merry Robin")
    }

    func testAJoinWhileOfflineKeepsTheLeaveIfItFails() async {
        let source = FakeSource()
        let parts = make(source)
        await parts.board.join(as: "Jolly Sprout")
        source.failing = true
        parts.board.leave()
        await parts.board.sync()
        source.joinError = .unavailable
        let offline = await parts.board.join(as: "Merry Robin")
        XCTAssertFalse(offline)
        XCTAssertTrue(parts.board.hasSomethingToSend, "The leave still waits")
        source.failing = false
        source.joinError = nil
        let back = await parts.board.join(as: "Merry Robin")
        XCTAssertTrue(back)
        XCTAssertFalse(parts.board.hasSomethingToSend)
    }

    // MARK: The Worker's wire format

    func testThePlayerKeyIsTheWorkersShape() {
        let key = HolidayPlayerKey.make(fromHardwareUUID: "12345678-ABCD-EF00-1234-56789ABCDEF0")
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(key, HolidayPlayerKey.make(fromHardwareUUID: "12345678-abcd-ef00-1234-56789abcdef0"), "Case doesn't matter")
        XCTAssertNotEqual(key, HolidayPlayerKey.make(fromHardwareUUID: "12345678-ABCD-EF00-1234-56789ABCDEF1"))
    }

    func testTheClientSpeaksTheWorkersAPI() async throws {
        var sent: [URLRequest] = []
        var replies: [(Int, String)] = [
            (200, #"{"ok":true,"id":"ab12","name":"Merry Robin","score":5,"counts":{"santa":3,"reindeer":1,"elf":0,"krampus":0}}"#),
            (200, #"{"ok":true,"score":7}"#),
            (200, #"{"ok":true,"season":2026,"open":true,"playerCount":31,"players":[{"id":"ab12","name":"Merry Robin","score":7,"counts":{"santa":5,"reindeer":1,"elf":0,"krampus":0},"gifts":["golden_mouse"]}],"you":{"id":"ab12","name":"Merry Robin","score":7,"counts":{"santa":5,"reindeer":1,"elf":0,"krampus":0},"gifts":["golden_mouse"],"rank":1}}"#),
            (200, #"{"ok":true,"gifts":["socks","banana","coal"],"opened":[1]}"#),
            (400, #"{"ok":false,"error":"bad_name"}"#),
            (410, #"{"ok":false,"error":"season_closed"}"#),
        ]
        let client = HolidaySantaClient(base: URL(string: "https://reports.example")!, key: String(repeating: "a", count: 64)) { request in
            sent.append(request)
            let (status, body) = replies.removeFirst()
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let joined = try await client.join(name: "Jolly Sprout")
        XCTAssertEqual(joined, HolidayJoinReply(name: "Merry Robin", counts: [.santa: 3, .reindeer: 1, .elf: 0, .krampus: 0]))
        let stored = try await client.score([.santa: 5, .reindeer: 1])
        XCTAssertEqual(stored, 7)
        let board = try await client.board(you: HolidayPlayer(id: "you", name: "x", score: 0, counts: [:], gifts: [], isYou: true))
        XCTAssertEqual(board.playerCount, 31)
        XCTAssertEqual(board.yourRank, 1)
        XCTAssertEqual(board.top.first?.isYou, true)
        XCTAssertEqual(board.top.first?.gifts, [.goldenMouse])
        let presents = try await client.presents(opened: [1])
        XCTAssertEqual(presents, HolidayPresentsReply(gifts: [.socks, .banana, .coal], opened: [1]))
        do { _ = try await client.join(name: "Bad"); XCTFail() } catch { XCTAssertEqual(error as? HolidaySantaError, .badName) }
        do { try await client.leave(); XCTFail() } catch { XCTAssertEqual(error as? HolidaySantaError, .seasonClosed) }

        // Every request a POST with JSON to /v1/santa/<route>, the key only in the body.
        XCTAssertEqual(sent.map(\.url!.path), ["/v1/santa/join", "/v1/santa/score", "/v1/santa/board", "/v1/santa/presents", "/v1/santa/join", "/v1/santa/leave"])
        XCTAssertTrue(sent.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "content-type") == "application/json" })
        XCTAssertTrue(sent.allSatisfy { $0.url!.query == nil })
        let score = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1].httpBody!) as? [String: Any])
        XCTAssertEqual(score["key"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(score["score"] as? Int, 7)
        XCTAssertEqual(score["counts"] as? [String: Int], ["santa": 5, "reindeer": 1, "elf": 0, "krampus": 0])
    }

    func testTheBoardIsAPlainGetBeforeJoining() async throws {
        var sent: [URLRequest] = []
        let client = HolidaySantaClient(base: URL(string: "https://reports.example")!, key: String(repeating: "a", count: 64)) { request in
            sent.append(request)
            return (Data(#"{"ok":true,"season":2026,"open":true,"playerCount":12}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let board = try await client.board(you: nil)
        XCTAssertEqual(board, HolidayBoard(playerCount: 12))
        XCTAssertEqual(sent.first?.httpMethod, "GET")
        XCTAssertNil(sent.first?.httpBody, "No key without joining")
    }

    /// The real client against a Worker running locally (`wrangler dev` with a December date):
    /// `MACRAZER_SANTA_TEST_URL=http://localhost:8789 swift test --filter testAgainstALocalWorker`.
    /// Skipped without it.
    func testAgainstALocalWorker() async throws {
        guard let text = ProcessInfo.processInfo.environment["MACRAZER_SANTA_TEST_URL"], let base = URL(string: text) else {
            throw XCTSkip("Set MACRAZER_SANTA_TEST_URL to a local Worker")
        }
        at(2026, 12, 25)
        let parts = make(nil)
        parts.board.configure(base: base, hardwareUUID: UUID().uuidString, send: { try await URLSession.shared.data(for: $0) })
        let joined = await parts.board.join(as: "Live Test Robin")
        XCTAssertTrue(joined, parts.board.problem ?? "")
        let refused = await parts.board.join(as: "Fuck Face")
        XCTAssertFalse(refused)
        XCTAssertEqual(parts.board.problem, "That name isn't allowed. Try another one.")
        let spot = UUID()
        parts.game.register(spot, surface: .popover)
        for character in [HolidayCharacter.santa, .reindeer, .krampus] {
            parts.game.caught(parts.game.forcePeek(character, spot: spot).id)
        }
        await parts.board.sync()
        await parts.board.refreshNow()
        XCTAssertNotNil(parts.board.board)
        XCTAssertEqual(parts.presents.gifts.count, 3, "The Worker picked the presents")
        let first = parts.presents.gifts
        _ = parts.presents.open(1)
        await parts.board.syncPresents()
        XCTAssertEqual(parts.presents.gifts, first)
        parts.board.leave()
        await parts.board.sync()
        XCTAssertNil(parts.board.name)
    }
}

/// A Worker that remembers what it was asked.
@MainActor
private final class FakeSource: HolidayBoardSource {
    var calls: [String] = []
    var joinName: String?
    var joinError: HolidaySantaError?
    var scoreError: HolidaySantaError?
    var failing = false
    var storesScores = true
    var board: HolidayBoard?
    var boardFails = false
    var boardScoreSent: Int?
    /// Answers only after a long wait, or when cancelled.
    var slow = false
    var stored: [HolidayCharacter: Int] = [:]
    var sentCounts: [HolidayCharacter: Int]?
    var gifts: [HolidayGift] = []
    var openedSent: Set<Int> = []
    var presentsFail = false
    /// Seconds before the presents or a leave answer.
    var presentsDelay: Double = 0
    var leaveDelay: Double = 0

    func join(name: String) async throws -> HolidayJoinReply {
        calls.append("join")
        if let joinError { throw joinError }
        return HolidayJoinReply(name: joinName ?? name, counts: stored)
    }

    func score(_ counts: [HolidayCharacter: Int]) async throws -> Int {
        calls.append("score")
        if slow { try await Task.sleep(for: .seconds(30)) }
        if let scoreError { throw scoreError }
        sentCounts = counts
        if storesScores { stored = counts }
        return HolidayLeaderboard.points(stored)
    }

    func leave() async throws {
        calls.append("leave")
        if leaveDelay > 0 { try await Task.sleep(for: .seconds(leaveDelay)) }
        if failing { throw HolidaySantaError.unavailable }
    }

    func board(you: HolidayPlayer?) async throws -> HolidayBoard {
        calls.append("board")
        if boardFails { throw HolidaySantaError.unavailable }
        boardScoreSent = you?.score
        return board ?? HolidayBoard(playerCount: 3)
    }

    func presents(opened: Set<Int>) async throws -> HolidayPresentsReply {
        calls.append("presents")
        if presentsDelay > 0 { try await Task.sleep(for: .seconds(presentsDelay)) }
        if presentsFail { throw HolidaySantaError.unavailable }
        openedSent = opened
        return HolidayPresentsReply(gifts: gifts, opened: opened)
    }
}

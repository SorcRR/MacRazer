// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

private let base = URL(string: "https://reports.example.org")
private let cobra = UsagePing.Mouse(pid: 0xDB, name: "Razer Cobra HyperSpeed", link: "dongle", supported: true)
private let basilisk = UsagePing.Mouse(pid: 0x99, name: "Basilisk V3 X", link: "bluetooth", supported: false)
/// 2026-11-04 23:30 UTC, half an hour before the Worker's day turns.
private let lateEvening = Date(timeIntervalSince1970: 1_793_835_000)

@MainActor
final class AnonymousCountReporterTests: XCTestCase {
    /// A fresh store per reporter, so no test sees another's sends.
    private func freshDefaults() -> UserDefaults {
        let suite = "AnonymousCountReporterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A reporter whose requests are answered with `status`, or fail when it's nil. The Worker
    /// says it recorded the count (`x-counted: 1`) when `counted` says so, by default on a 200.
    /// `requests` collects every URL it asked for.
    private func reporter(at date: @escaping () -> Date, status: @escaping () -> Int?,
                          counted: @escaping (Int) -> Bool = { $0 == 200 },
                          requests: @escaping (URL) -> Void) -> AnonymousCountReporter {
        AnonymousCountReporter(defaults: freshDefaults(), base: base, appVersion: "0.7.1", now: date) { url in
            requests(url)
            guard let code = status() else { throw URLError(.notConnectedToInternet) }
            let headers = ["x-counted": counted(code) ? "1" : "0"]
            return (Data("[]".utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!)
        }
    }

    func testOnlyACountTheWorkerSaysItRecordedIsDone() async {
        var asked: [URL] = []
        var answer = 200
        var recorded = false
        var clock = lateEvening.addingTimeInterval(-3 * 3600)
        let sut = reporter(at: { clock }, status: { answer }, counted: { _ in recorded }, requests: { asked.append($0) })
        sut.connectedMice = { [cobra] }
        await sut.reportIfNeeded()
        await sut.reportIfNeeded()
        XCTAssertEqual(asked.count, 1, "refused: nothing more until the next tick, however often it's asked")
        clock = clock.addingTimeInterval(AnonymousCountReporter.retryAfter)
        await sut.reportIfNeeded()
        XCTAssertEqual(asked.count, 2, "a 200 without x-counted (a burst, the cap, a database error) is sent again")
        answer = 502
        recorded = true
        clock = clock.addingTimeInterval(AnonymousCountReporter.retryAfter)
        await sut.reportIfNeeded()
        await sut.reportIfNeeded()
        XCTAssertEqual(asked.count, 3, "a 502 with x-counted: the list failed, the count is in")
    }

    func testAWorkerFromBeforeTheHeaderIsTakenAtItsStatus() {
        let url = URL(string: "https://reports.example.org/v1/releases")!
        let answer = { (code: Int, headers: [String: String]?) in
            AnonymousCountReporter.counted(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!)
        }
        XCTAssertTrue(answer(200, nil), "no header: an older Worker, which counted it as before")
        XCTAssertFalse(answer(503, nil))
        XCTAssertFalse(answer(200, ["x-counted": "0"]), "said it didn't")
        XCTAssertTrue(answer(502, ["x-counted": "1"]), "the list failed, the count is in")
    }

    func testNoMouseSendsNothing() async {
        var asked: [URL] = []
        let sut = reporter(at: { lateEvening }, status: { 200 }, requests: { asked.append($0) })
        await sut.reportIfNeeded()
        XCTAssertTrue(asked.isEmpty)
    }

    func testAMouseGoesOutOnceADay() async throws {
        var asked: [URL] = []
        let sut = reporter(at: { lateEvening }, status: { 200 }, requests: { asked.append($0) })
        sut.connectedMice = { [cobra] }
        await sut.reportIfNeeded()
        await sut.reportIfNeeded()
        XCTAssertEqual(asked.count, 1)
        let items = try XCTUnwrap(URLComponents(url: asked[0], resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["app", "mouse", "count"])
        XCTAssertEqual(items[1].value, "00db.dongle.1.Razer Cobra HyperSpeed")
    }

    func testAFailedSendIsTriedAgain() async {
        var asked: [URL] = []
        var answer: Int? = nil
        var clock = lateEvening.addingTimeInterval(-3 * 3600)
        let sut = reporter(at: { clock }, status: { answer }, requests: { asked.append($0) })
        sut.connectedMice = { [cobra] }
        await sut.reportIfNeeded()
        answer = 503
        await sut.reportIfNeeded()
        answer = 200
        clock = clock.addingTimeInterval(AnonymousCountReporter.retryAfter)
        await sut.reportIfNeeded()
        await sut.reportIfNeeded()
        XCTAssertEqual(asked.count, 3, "offline and a 503 both leave it due; the 200 settles it")
    }

    func testANewMouseTheSameDayGoesOutWithTheOthers() async throws {
        var asked: [URL] = []
        var mice = [cobra]
        let sut = reporter(at: { lateEvening }, status: { 200 }, requests: { asked.append($0) })
        sut.connectedMice = { mice }
        await sut.reportIfNeeded()
        mice = [cobra, basilisk]
        await sut.reportIfNeeded()
        mice = [basilisk]
        await sut.reportIfNeeded()
        XCTAssertEqual(asked.count, 2)
        let items = try XCTUnwrap(URLComponents(url: asked[1], resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "mouse" }.count, 2)
    }

    func testTheNextUTCDaySendsAgain() async {
        var asked: [URL] = []
        var now = lateEvening
        let sut = reporter(at: { now }, status: { 200 }, requests: { asked.append($0) })
        sut.connectedMice = { [cobra] }
        await sut.reportIfNeeded()
        now = lateEvening.addingTimeInterval(20 * 60)
        await sut.reportIfNeeded()
        now = lateEvening.addingTimeInterval(40 * 60)
        await sut.reportIfNeeded()
        XCTAssertEqual(asked.count, 2, "one for the 4th, one once it's the 5th in UTC")
    }

    func testABuildWithoutAWorkerSendsNothing() async {
        var asked: [URL] = []
        let sut = AnonymousCountReporter(defaults: freshDefaults(), base: nil, appVersion: "0.7.1", now: { lateEvening }) { url in
            asked.append(url)
            return (Data(), URLResponse())
        }
        sut.connectedMice = { [cobra] }
        await sut.reportIfNeeded()
        XCTAssertTrue(asked.isEmpty)
    }

    func testTheAnswerGoesOutOnceADayEvenWithNoMouse() async throws {
        var asked: [URL] = []
        var now = lateEvening
        let sut = reporter(at: { now }, status: { 200 }, requests: { asked.append($0) })
        sut.answer = { .declined }
        await sut.reportIfNeeded()
        await sut.reportIfNeeded()
        now = lateEvening.addingTimeInterval(40 * 60)
        await sut.reportIfNeeded()
        XCTAssertEqual(asked.count, 2)
        let items = try XCTUnwrap(URLComponents(url: asked[0], resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["app", "stats", "count"])
        XCTAssertEqual(items[1].value, "no")
    }

    func testAChangedAnswerGoesOutWithItsChangeUntilTheWorkerHasIt() async throws {
        var asked: [URL] = []
        var answer: Int? = nil
        var consent = UsageStatsConsent.granted
        var pending: [UsageStatsConsent.Change] = []
        let sut = reporter(at: { lateEvening }, status: { answer }, requests: { asked.append($0) })
        sut.answer = { consent }
        sut.pendingChanges = { pending }
        sut.changesSent = { sent in pending.removeAll { sent.contains($0) } }
        answer = 200
        await sut.reportIfNeeded()
        consent = .declined
        pending = [.turnedOff]
        answer = nil
        await sut.reportIfNeeded()
        XCTAssertEqual(pending, [.turnedOff], "kept while offline")
        answer = 200
        await sut.reportIfNeeded()
        await sut.reportIfNeeded()
        XCTAssertEqual(asked.count, 3)
        XCTAssertTrue(pending.isEmpty)
        let items = try XCTUnwrap(URLComponents(url: asked[2], resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["app", "stats", "change", "count"])
        XCTAssertEqual(items.map(\.value), ["0.7.1", "no", "turned_off", "1"])
    }

    func testTheDayIsUTC() {
        XCTAssertEqual(AnonymousCountReporter.day(of: lateEvening), "2026-11-04")
        XCTAssertEqual(AnonymousCountReporter.day(of: lateEvening.addingTimeInterval(31 * 60)), "2026-11-05")
    }
}

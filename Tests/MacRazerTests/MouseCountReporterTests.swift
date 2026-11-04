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
final class MouseCountReporterTests: XCTestCase {
    /// A fresh store per reporter, so no test sees another's sends.
    private func freshDefaults() -> UserDefaults {
        let suite = "MouseCountReporterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A reporter whose requests are answered with `status`, or fail when it's nil. `requests`
    /// collects every URL it asked for.
    private func reporter(at date: @escaping () -> Date, status: @escaping () -> Int?,
                          requests: @escaping (URL) -> Void) -> MouseCountReporter {
        MouseCountReporter(defaults: freshDefaults(), base: base, appVersion: "0.7.1", now: date) { url in
            requests(url)
            guard let code = status() else { throw URLError(.notConnectedToInternet) }
            return (Data("[]".utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
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
        XCTAssertEqual(items.map(\.name), ["app", "mouse"])
        XCTAssertEqual(items[1].value, "00db.dongle.1.Razer Cobra HyperSpeed")
    }

    func testAFailedSendIsTriedAgain() async {
        var asked: [URL] = []
        var answer: Int? = nil
        let sut = reporter(at: { lateEvening }, status: { answer }, requests: { asked.append($0) })
        sut.connectedMice = { [cobra] }
        await sut.reportIfNeeded()
        answer = 503
        await sut.reportIfNeeded()
        answer = 200
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
        let sut = MouseCountReporter(defaults: freshDefaults(), base: nil, appVersion: "0.7.1", now: { lateEvening }) { url in
            asked.append(url)
            return (Data(), URLResponse())
        }
        sut.connectedMice = { [cobra] }
        await sut.reportIfNeeded()
        XCTAssertTrue(asked.isEmpty)
    }

    func testTheDayIsUTC() {
        XCTAssertEqual(MouseCountReporter.day(of: lateEvening), "2026-11-04")
        XCTAssertEqual(MouseCountReporter.day(of: lateEvening.addingTimeInterval(31 * 60)), "2026-11-05")
    }
}

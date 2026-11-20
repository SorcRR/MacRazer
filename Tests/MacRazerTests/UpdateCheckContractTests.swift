// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The contract with the Worker for counting apps: which requests are the plain update check
/// and which are this Mac's daily count. The Worker counts a Mac once a day where its daily
/// count came from, and leaves a plain check from another address out (macrazer-worker,
/// migration 0010), so a change in either request changes the numbers. The Worker's tests
/// read update-check.json and check each request is told apart as it should be. Run with
/// UPDATE_WORKER_FIXTURE=1 to rewrite it after changing either request.
@MainActor
final class UpdateCheckContractTests: XCTestCase {
    private static let base = URL(string: "https://reports.example.org")
    private static let version = "0.9.0"
    private static let cobra = UsagePing.Mouse(pid: 0xDB, name: "Razer Cobra HyperSpeed", link: "dongle", supported: true)

    private static var fixture: URL { WorkerFixtures.url("update-check.json") }

    /// What one daily count sends, through the real reporter.
    private func daily(answer: UsageStatsConsent?, mice: [UsagePing.Mouse] = [],
                       changes: [UsageStatsConsent.Change] = []) async throws -> String {
        let suite = "UpdateCheckContractTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        var asked: [URL] = []
        let reporter = AnonymousCountReporter(defaults: defaults, base: Self.base, appVersion: Self.version,
                                              now: { Date(timeIntervalSince1970: 1_793_800_000) }) { url in
            asked.append(url)
            return (Data("[]".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["x-counted": "1"])!)
        }
        reporter.connectedMice = { mice }
        reporter.answer = { answer }
        reporter.pendingChanges = { changes }
        await reporter.reportIfNeeded()
        XCTAssertEqual(asked.count, 1)
        return try Self.request(XCTUnwrap(asked.first))
    }

    /// The path and query, as the Worker reads them.
    private static func request(_ url: URL) -> String {
        url.path + (url.query.map { "?" + $0 } ?? "")
    }

    func testTheWorkerTellsTheUpdateCheckFromTheDailyCount() async throws {
        let plain = try Self.request(XCTUnwrap(UpdateChecker.workerCheck(appVersion: Self.version, base: Self.base)))
        let daily = [
            ("an answer", try await daily(answer: .declined)),
            ("an answer and a mouse", try await daily(answer: .granted, mice: [Self.cobra])),
            ("a mouse while the question is on screen", try await daily(answer: nil, mice: [Self.cobra])),
            ("a closed question", try await daily(answer: .undecided, changes: [.dismissed])),
        ]
        let contract: [String: Any] = [
            "plain": [["name": "the update check", "request": plain]],
            "daily": daily.map { ["name": $0.0, "request": $0.1] },
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: contract, options: [.prettyPrinted, .sortedKeys]),
                          as: UTF8.self) + "\n"
        if ProcessInfo.processInfo.environment["UPDATE_WORKER_FIXTURE"] == "1" {
            try json.write(to: Self.fixture, atomically: true, encoding: .utf8)
        }
        func parsed(_ data: Data) throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }
        XCTAssertEqual(try parsed(Data(contentsOf: Self.fixture)), try parsed(Data(json.utf8)), """
            The update check or the daily count changed. Rewrite the fixture with UPDATE_WORKER_FIXTURE=1 swift test \
            --filter UpdateCheckContractTests, check src/releases.ts in SorcRR/macrazer-worker still tells them apart \
            (its "update check contract" test), and run its tests.
            """)
    }
}

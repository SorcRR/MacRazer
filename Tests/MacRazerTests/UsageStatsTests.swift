// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// Usage stats: when a ping is due, what's in it, the ID, and Delete My Data. Plus the
/// contract with the Worker's `stats.ts`, through a shared fixture.
@MainActor
final class UsageStatsTests: XCTestCase {
    private let endpoint = URL(string: "https://reports.example/v1/stats")!
    private let cobra = UsagePing.Mouse(pid: 0x00B0, name: "Razer Cobra Pro (Wireless)", link: "dongle", supported: true)
    private let unknown = UsagePing.Mouse(pid: 0x00B6, name: "Razer DeathAdder V3 Pro", link: "unknown", supported: false)

    /// Records every request and answers each with the next status, 200 once they run out.
    /// A status of 0 is a request that never got an answer.
    final class FakeServer: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        private var statuses: [Int]
        init(_ statuses: [Int] = []) { self.statuses = statuses }

        var requests: [URLRequest] { lock.withLock { _requests } }
        var pings: [UsagePing] {
            requests.filter { $0.httpMethod == "POST" }.compactMap { $0.httpBody }
                .compactMap { try? JSONDecoder().decode(UsagePing.self, from: $0) }
        }

        func answer(_ statuses: Int...) { lock.withLock { self.statuses += statuses } }

        func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
            let status = lock.withLock {
                _requests.append(request)
                return statuses.isEmpty ? 200 : statuses.removeFirst()
            }
            if status == 0 { throw URLError(.notConnectedToInternet) }
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func defaults() -> UserDefaults {
        let name = "MacRazerTests.UsageStats.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func stats(_ server: FakeServer, defaults: UserDefaults? = nil, version: String? = "0.6.0",
                       uuid: String? = "5C0FFEE0-0000-4000-8000-000000000000") -> UsageStats {
        UsageStats(defaults: defaults ?? self.defaults(), endpoint: endpoint, version: version,
                   hardwareUUID: { uuid }, sendsOnChange: false, transport: { try server.handle($0) })
    }

    // MARK: The contract with the Worker

    private static var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("worker/test/fixtures/usage-ping.json")
    }

    /// The Worker's tests check it accepts this file as it is. Run with
    /// UPDATE_WORKER_FIXTURE=1 to rewrite it after changing the ping.
    func testTheWorkerTakesThePingAsSent() throws {
        let ping = UsagePing(id: "3f9a0c71e2b84d6a9c15e0b7d4a2f816", event: .update, app: "0.6.0",
                             os: "26.1", arch: "arm64", mice: [cobra])
        let json = ping.json(pretty: false) + "\n"
        if ProcessInfo.processInfo.environment["UPDATE_WORKER_FIXTURE"] == "1" {
            try json.write(to: Self.fixture, atomically: true, encoding: .utf8)
        }
        func parsed(_ data: Data) throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }
        XCTAssertEqual(try parsed(Data(contentsOf: Self.fixture)), try parsed(Data(json.utf8)), """
            The ping's format changed. Rewrite the fixture with UPDATE_WORKER_FIXTURE=1 swift test \
            --filter UsageStatsTests, update worker/src/stats.ts to match, and run the Worker's tests.
            """)
    }

    // MARK: When a ping is due

    func testNothingIsDueWithoutAYes() {
        for consent in [UsageStatsConsent.undecided, .declined] {
            XCTAssertNil(UsageStatsPolicy.event(consent: consent, version: "0.6.0", lastReportedVersion: nil,
                                                reportedMice: [], connected: [cobra]))
        }
    }

    func testADevBuildNeverSends() {
        XCTAssertNil(UsageStatsPolicy.event(consent: .granted, version: nil, lastReportedVersion: nil,
                                            reportedMice: [], connected: [cobra]))
    }

    func testFirstThenUpdateThenNewMice() {
        func event(_ last: String?, _ reported: Set<String>, _ connected: [UsagePing.Mouse]) -> UsagePing.Event? {
            UsageStatsPolicy.event(consent: .granted, version: "0.6.0", lastReportedVersion: last,
                                   reportedMice: reported, connected: connected)
        }
        XCTAssertEqual(event(nil, [], []), .first)
        XCTAssertEqual(event("0.5.0", [cobra.key], [cobra]), .update)
        XCTAssertEqual(event("0.6.0", [cobra.key], [cobra, unknown]), .mouse)
        XCTAssertNil(event("0.6.0", [cobra.key], [cobra]))
        XCTAssertNil(event("0.6.0", [cobra.key], []), "a mouse going away isn't news")
    }

    func testAMouseIsNamedAndLinkedTheWayTheRegistryKnowsIt() {
        let known = UsageStatsPolicy.mouse(pid: 0x00B0, productName: "Razer Cobra Pro", isBluetooth: false, supported: true)
        XCTAssertEqual(known, cobra, "the registry's name, so one model counts under one name")
        let bluetooth = UsageStatsPolicy.mouse(pid: 0x00DC, productName: nil, isBluetooth: true, supported: true)
        XCTAssertEqual(bluetooth.link, "bluetooth")
        let stranger = UsageStatsPolicy.mouse(pid: 0x7777, productName: "Razer Something New", isBluetooth: false, supported: false)
        XCTAssertEqual(stranger, UsagePing.Mouse(pid: 0x7777, name: "Razer Something New", link: "unknown", supported: false))
        XCTAssertEqual(UsageStatsPolicy.mouse(pid: 0x7777, productName: nil, isBluetooth: false, supported: false).name, "Unknown mouse")
        let long = UsageStatsPolicy.mouse(pid: 0x7777, productName: String(repeating: "x", count: 100), isBluetooth: false, supported: false)
        XCTAssertEqual(long.name.count, 64, "the Worker's limit")
        let emoji = UsageStatsPolicy.fitted(String(repeating: "a", count: 63) + "🖱️x", utf16: 64)
        XCTAssertEqual(emoji, String(repeating: "a", count: 63), "an emoji isn't cut in half")
    }

    // MARK: The ID

    func testTheIDIsTheSameForTheSameMacAndUnlikeTheUUID() {
        let uuid = "5C0FFEE0-0000-4000-8000-000000000000"
        let id = UsageMachineID.id(fromHardwareUUID: uuid)
        XCTAssertEqual(id, UsageMachineID.id(fromHardwareUUID: uuid.lowercased()), "case doesn't make a new Mac")
        XCTAssertNotEqual(id, UsageMachineID.id(fromHardwareUUID: "5C0FFEE0-0000-4000-8000-000000000001"))
        XCTAssertTrue(id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil, "the Worker's format")
        XCTAssertFalse(id.contains("5c0ffee0"))
    }

    func testTheIDIsKeptAndSurvivesAReinstallWithEmptyPreferences() {
        let server = FakeServer()
        let first = stats(server).machineID
        XCTAssertEqual(stats(server).machineID, first, "empty preferences, same Mac, same ID")
        let d = defaults()
        let kept = stats(server, defaults: d).machineID
        XCTAssertEqual(stats(server, defaults: d, uuid: "SOMETHING-ELSE").machineID, kept,
                       "once worked out, a changed UUID doesn't make it a new Mac")
    }

    func testAMacWithNoUUIDStillGetsAValidID() {
        let id = stats(FakeServer(), uuid: nil).machineID
        XCTAssertTrue(id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil)
    }

    func testTheArchIsTheChipNotTheProcess() {
        XCTAssertTrue(["arm64", "x86_64"].contains(UsageMachineID.arch))
    }

    // MARK: Sending

    func testNothingGoesOutUntilTheAnswerIsYes() async {
        let server = FakeServer()
        let s = stats(server)
        s.setConnectedMice([cobra])
        await s.sendIfDue()
        XCTAssertTrue(server.requests.isEmpty)
        s.dismissUnanswered()
        XCTAssertEqual(s.consent, .declined, "closing the question is a no")
        await s.sendIfDue()
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAYesSendsOnceThenOnlyWhatsNew() async throws {
        let server = FakeServer()
        let d = defaults()
        let s = stats(server, defaults: d)
        s.setConnectedMice([cobra])
        s.setConsent(true)
        await s.sendIfDue()
        await s.sendIfDue()
        XCTAssertEqual(server.pings.map(\.event), [.first])
        let ping = try XCTUnwrap(server.pings.first)
        XCTAssertEqual(ping.mice, [cobra])
        XCTAssertEqual(ping.app, "0.6.0")
        XCTAssertEqual(ping.id, s.machineID)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNotNil(s.lastSentAt)
        XCTAssertEqual(s.lastSentVersion, "0.6.0")

        s.setConnectedMice([cobra, unknown])
        await s.sendIfDue()
        XCTAssertEqual(server.pings.map(\.event), [.first, .mouse])

        let updated = stats(server, defaults: d, version: "0.7.0")
        await updated.sendIfDue()
        XCTAssertEqual(server.pings.map(\.event), [.first, .mouse, .update])
        XCTAssertEqual(server.pings.last?.id, ping.id)
    }

    func testAFailedPingIsDueAgain() async {
        let server = FakeServer([0, 503])
        let s = stats(server)
        s.setConsent(true)
        await s.sendIfDue()
        await s.sendIfDue()
        XCTAssertNil(s.lastSentAt)
        await s.sendIfDue()
        XCTAssertEqual(server.pings.map(\.event), [.first, .first, .first])
        XCTAssertNotNil(s.lastSentAt)
    }

    // MARK: Delete My Data

    func testDeleteMyDataTurnsSharingOffAndAsksTheServer() async throws {
        let server = FakeServer()
        let s = stats(server)
        s.setConsent(true)
        await s.sendIfDue()
        await s.deleteMyData()
        XCTAssertEqual(s.consent, .declined)
        XCTAssertEqual(s.deletion, .deleted)
        XCTAssertNil(s.lastSentAt)
        let delete = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(delete.httpMethod, "DELETE")
        XCTAssertEqual(delete.url, endpoint.appendingPathComponent(s.machineID))
        XCTAssertNil(delete.httpBody)
    }

    func testAnUnreachableDeleteIsKeptAndRetriedNextLaunch() async {
        let server = FakeServer()
        let d = defaults()
        let s = stats(server, defaults: d)
        s.setConsent(true)
        await s.sendIfDue()
        server.answer(0)
        await s.deleteMyData()
        XCTAssertEqual(s.deletion, .willRetry)

        let nextLaunch = stats(server, defaults: d)
        XCTAssertEqual(nextLaunch.deletion, .willRetry, "still owed, and shown so")
        await nextLaunch.sendIfDue()
        XCTAssertEqual(nextLaunch.deletion, .deleted)
        XCTAssertEqual(server.requests.filter { $0.httpMethod == "DELETE" }.count, 2)
    }

    func testOptingInAgainWaitsForTheOwedDeleteThenStartsOver() async {
        let server = FakeServer()
        let s = stats(server)
        s.setConsent(true)
        await s.sendIfDue()
        server.answer(0)
        await s.deleteMyData()
        // Opting in while the delete is still owed: a ping now would be wiped by it later.
        server.answer(0)
        s.setConsent(true)
        await s.sendIfDue()
        XCTAssertEqual(server.requests.map { $0.httpMethod ?? "" }, ["POST", "DELETE", "DELETE"])
        await s.sendIfDue()
        XCTAssertEqual(server.requests.map { $0.httpMethod ?? "" }, ["POST", "DELETE", "DELETE", "DELETE", "POST"])
        XCTAssertEqual(server.pings.last?.event, .first, "a new start, as the server sees it")
    }

    func testADeleteMadeDuringAFailingPingStillGoesOut() async {
        final class Box: @unchecked Sendable { var stats: UsageStats? }
        let server = FakeServer([0])
        let box = Box()
        // The first request, the ping, is still waiting for an answer when Delete is clicked.
        let s = UsageStats(defaults: defaults(), endpoint: endpoint, version: "0.6.0",
                       hardwareUUID: { "5C0FFEE0-0000-4000-8000-000000000000" }, sendsOnChange: false,
                       transport: { [server, box] request in
                           if request.httpMethod == "POST" { await box.stats?.deleteMyData() }
                           return try server.handle(request)
                       })
        box.stats = s
        s.setConsent(true)
        XCTAssertEqual(s.deletion, .idle)
        await s.sendIfDue()
        XCTAssertEqual(server.requests.map { $0.httpMethod ?? "" }, ["POST", "DELETE"],
                       "the delete didn't wait for the next launch")
        XCTAssertEqual(s.deletion, .deleted)
        XCTAssertEqual(s.consent, .declined)
        XCTAssertNil(s.lastSentAt)
    }

    func testThePreviewIsWhatWouldGo() {
        let s = stats(FakeServer())
        s.setConnectedMice([cobra])
        let preview = s.preview
        XCTAssertEqual(preview.id, s.machineID)
        XCTAssertEqual(preview.mice, [cobra])
        XCTAssertEqual(preview.event, .first)
        XCTAssertTrue(preview.json(pretty: true).contains("\"Razer Cobra Pro (Wireless)\""))
    }
}

/// A build without the Worker: what someone else's clone or fork gets.
@MainActor
final class WorkerEndpointTests: XCTestCase {
    func testOnlyAnHTTPSOriginCounts() {
        XCTAssertEqual(WorkerEndpoint.parse("https://reports.example.org")?.absoluteString, "https://reports.example.org")
        XCTAssertEqual(WorkerEndpoint.parse("https://reports.example.org/")?.absoluteString, "https://reports.example.org")
        XCTAssertEqual(WorkerEndpoint.parse("http://127.0.0.1:8787")?.absoluteString, "http://127.0.0.1:8787",
                       "plain http only for wrangler dev on this Mac")
        for bad in [nil, "", "reports.example.org", "http://reports.example.org", "https://", "ftp://x.org",
                    "https://x.org/v1", "https://x.org?a=1", "https://u:p@x.org", "https://x.org#f"] {
            XCTAssertNil(WorkerEndpoint.parse(bad), bad ?? "nil")
        }
    }

    func testOnlyADevelopmentBuildTakesTheEnvironmentOverride() {
        let local = "http://127.0.0.1:8787", bundled = "https://reports.example.org"
        XCTAssertEqual(WorkerEndpoint.resolve(environment: local, bundled: bundled, isPackaged: true)?.absoluteString, bundled)
        XCTAssertNil(WorkerEndpoint.resolve(environment: local, bundled: nil, isPackaged: true))
        XCTAssertEqual(WorkerEndpoint.resolve(environment: local, bundled: nil, isPackaged: false)?.absoluteString, local)
        XCTAssertNil(WorkerEndpoint.resolve(environment: nil, bundled: nil, isPackaged: false))
    }

    func testTheRoutesHangOffTheOrigin() throws {
        let base = try XCTUnwrap(WorkerEndpoint.parse("https://reports.example.org"))
        XCTAssertEqual(base.appendingPathComponent("v1/stats").absoluteString, "https://reports.example.org/v1/stats")
    }

    func testStatsWithoutAWorkerNeverAskOrSend() async {
        let server = UsageStatsTests.FakeServer()
        let name = "MacRazerTests.NoWorker.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let s = UsageStats(defaults: UserDefaults(suiteName: name)!, endpoint: nil, version: "0.6.0",
                           hardwareUUID: { "X" }, sendsOnChange: false, transport: { try server.handle($0) })
        XCTAssertFalse(s.isAvailable)
        s.setConsent(true)
        await s.sendIfDue()
        await s.deleteMyData()
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testTheDeviceTestHasNoSendWithoutAWorker() {
        let model = DeviceTestModel(controller: MouseController(), permissions: PermissionsModel(), reportEndpoint: nil)
        XCTAssertFalse(model.canSend)
        XCTAssertTrue(DeviceTestModel(controller: MouseController(), permissions: PermissionsModel(),
                                      reportEndpoint: URL(string: "https://reports.example.org/v1/device-report")).canSend)
    }
}

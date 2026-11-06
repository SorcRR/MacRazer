// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The Worker's answer, as src/support-list.ts writes it.
private func listJSON(version: String = "0.7.0", schema: Int = 1, mice: String) -> Data {
    Data(#"{"schema":\#(schema),"version":"\#(version)","commit":"13b5a55ee4bde071ec52928428fc2c9c2a5d3209","mice":[\#(mice)]}"#.utf8)
}

final class SupportListDecodeTests: XCTestCase {
    func testReadsRowsTheAppKnows() throws {
        let list = try XCTUnwrap(SupportList.decode(listJSON(mice: #"""
            {"pid":234,"link":"dongle","unverified":["polling"]},{"pid":219,"link":"dongle","unverified":[]}
            """#)))
        XCTAssertEqual(list.version, "0.7.0")
        XCTAssertEqual(list.remaining, [0x00EA: [.polling], 0x00DB: []])
    }

    func testRefusesWhatItCannotRead() {
        XCTAssertNil(SupportList.decode(listJSON(schema: 2, mice: "")), "a newer shape")
        XCTAssertNil(SupportList.decode(Data("<html>".utf8)), "a captive portal's page")
        XCTAssertNil(SupportList.decode(Data(#"{"schema":1}"#.utf8)))
        let row = #"{"pid":234,"link":"dongle","unverified":[]}"#
        let tooMany = Array(repeating: row, count: SupportList.maxRows + 1).joined(separator: ",")
        XCTAssertNil(SupportList.decode(listJSON(mice: tooMany)))
        XCTAssertNil(SupportList.decode(Data(count: SupportList.maxBytes + 1)))
    }

    func testDropsRowsItCannotTrust() throws {
        let list = try XCTUnwrap(SupportList.decode(listJSON(mice: #"""
            {"pid":234,"link":"dongle","unverified":["polling","scroll"]},
            {"pid":235,"link":"dongle","unverified":[]},
            {"pid":39321,"link":"wired","unverified":[]}
            """#)))
        // An unknown feature must not count as confirmed, so the whole row goes. 0x00EB is the
        // cable row, not a dongle, and 0x9999 isn't one the app can drive.
        XCTAssertEqual(list.remaining, [:])
    }

    func testAppliesOnlyToTheVersionItWasMadeFor() throws {
        let list = try XCTUnwrap(SupportList.decode(listJSON(version: "0.7.0", mice: "")))
        XCTAssertTrue(list.applies(to: "0.7.0"))
        XCTAssertTrue(list.applies(to: "0.7"), "the same version, written shorter")
        XCTAssertFalse(list.applies(to: "0.6.1"), "a newer release may have confirmed it with new code")
        XCTAssertFalse(list.applies(to: "0.8.0"), "this build's table is newer than the list")
        XCTAssertFalse(list.applies(to: "0.7.1"))
        XCTAssertTrue(list.applies(to: AppInfo.unversioned), "a swift run build, to try it against wrangler dev")
    }
}

final class SupportListOverlayTests: XCTestCase {
    /// A model whose every row still needs something, so confirming them all ends the ask.
    /// Found in the table rather than named, so a report verifying it doesn't break the test.
    private func modelStillAsking() throws -> [RazerDeviceInfo] {
        let models = Dictionary(grouping: RazerDevices.known) { RazerDevices.modelName($0.name) }.values
        return try XCTUnwrap(models.first { rows in
            rows.allSatisfy { !$0.unverified.isEmpty } && rows.count == 2
                && Set(rows.map(\.connection)) == [.wired, .wirelessDongle]
        }, "no wired + dongle model left with something unverified; pick another case")
    }

    /// A row with at least two features to confirm.
    private func rowWithSeveral() throws -> RazerDeviceInfo {
        try XCTUnwrap(RazerDevices.known.first { $0.unverified.count >= 2 })
    }

    override func tearDown() {
        RazerDevices.applySupportList([:])
        super.tearDown()
    }

    func testConfirmingAFeatureEndsTheAsk() throws {
        let rows = try modelStillAsking()
        let pid = rows[0].pid
        XCTAssertTrue(RazerDevices.needsReport(pid: pid))
        RazerDevices.applySupportList(Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, []) }))
        XCTAssertEqual(RazerDevices.support(pid: pid), .full)
        XCTAssertTrue(RazerDevices.fullySupported(pid: pid))
        XCTAssertEqual(RazerDevices.unverified(pid: pid), [])
        XCTAssertFalse(RazerDevices.needsReport(pid: pid), "both links confirmed")
        XCTAssertTrue(RazerDevices.fullySupported(modelOf: pid, on: rows[1].connection))
    }

    /// Verified on one link with the other's row still unverified: the verified row asks for
    /// just what the other link's row is missing, and a report from that link answers it.
    func testOneLinkVerifiedAsksForWhatTheOtherIsMissing() throws {
        let rows = try modelStillAsking()
        let (done, other) = (rows[0], rows[1])
        RazerDevices.applySupportList([done.pid: []])
        XCTAssertEqual(RazerDevices.support(pid: done.pid), .full)
        XCTAssertEqual(RazerDevices.linksToTest(besides: done.pid),
                       [.init(connection: other.connection, missing: other.unverified)])
        XCTAssertTrue(RazerDevices.needsReport(pid: done.pid), "the other link still needs a report")
        XCTAssertFalse(RazerDevices.fullySupported(modelOf: done.pid, on: other.connection))
        XCTAssertEqual(RazerDevices.rowsAnswered(byReportFrom: other.pid, name: other.name, on: other.connection),
                       [done.pid])
    }

    func testNarrowingKeepsTheRest() throws {
        let row = try rowWithSeveral()
        let kept = Array(row.unverified.suffix(2))
        RazerDevices.applySupportList([row.pid: Set(kept.reversed())])
        XCTAssertEqual(RazerDevices.unverified(pid: row.pid), kept, "the row's own test order")
        // Everything the row could show as working, once nothing is left to confirm.
        RazerDevices.applySupportList([row.pid: []])
        let all = RazerDevices.verified(pid: row.pid)
        let last = try XCTUnwrap(row.unverified.last)
        RazerDevices.applySupportList([row.pid: [last]])
        XCTAssertEqual(RazerDevices.unverified(pid: row.pid), [last])
        XCTAssertEqual(RazerDevices.verified(pid: row.pid), all.filter { $0 != last })
    }

    func testCanNeverAddToARow() throws {
        let done = try XCTUnwrap(RazerDevices.known.first { $0.unverified.isEmpty })
        let asking = try rowWithSeveral()
        RazerDevices.applySupportList([done.pid: Set(RazerFeature.allCases), asking.pid: Set(RazerFeature.allCases)])
        XCTAssertEqual(RazerDevices.unverified(pid: done.pid), [])
        XCTAssertEqual(RazerDevices.unverified(pid: asking.pid), asking.unverified)
    }

    func testAPidTheAppDoesNotKnowStaysUnknown() {
        RazerDevices.applySupportList([0x9999: []])
        XCTAssertEqual(RazerDevices.support(pid: 0x9999), .unknown)
        XCTAssertNil(RazerDevices.unverified(pid: 0x9999))
    }

    func testNothingThatTalksToTheMouseChanges() {
        struct Protocol: Equatable {
            let tids: [UInt8], maxDPI: Int, leds: [UInt8], battery: Bool, lighting: Bool
            let connection: RazerConnection?, polling: Bool
        }
        func snapshot() -> [Protocol] {
            RazerDevices.known.map { row in
                Protocol(tids: [(0x00, 0x83), (0x04, 0x05), (0x0F, 0x02), (0x0F, 0x04)].map {
                             RazerDevices.transactionId(pid: row.pid, commandClass: $0.0, commandId: $0.1) },
                         maxDPI: RazerDevices.maxDPI(pid: row.pid), leds: RazerDevices.brightnessLeds(pid: row.pid),
                         battery: RazerDevices.hasBattery(pid: row.pid), lighting: RazerDevices.hasLighting(pid: row.pid),
                         connection: RazerDevices.connection(pid: row.pid),
                         polling: RazerDevices.acceptsClassicPolling(pid: row.pid))
            }
        }
        let before = snapshot()
        RazerDevices.applySupportList(Dictionary(uniqueKeysWithValues: RazerDevices.known.map { ($0.pid, []) }))
        XCTAssertEqual(snapshot(), before)
    }

    /// A list landing mid-run leaves the title, intro and Skip as the run began.
    @MainActor func testARunningTestKeepsWhatItStartedWith() throws {
        let row = try rowWithSeveral()
        let model = DeviceTestModel(controller: MouseController(), permissions: PermissionsModel(), reportEndpoint: nil)
        model.loadPreview(.intro, pid: row.pid, ranSteps: false)
        let (support, missing) = (model.support, model.missingFeatures)
        model.pinForTesting()
        RazerDevices.applySupportList([row.pid: []])
        XCTAssertEqual(model.support, support)
        XCTAssertEqual(model.missingFeatures, missing)
        model.reset()
        XCTAssertEqual(model.support, .full, "back at the intro, it follows the list")
    }

    func testTellsObserversOnlyOnAChange() {
        var posts = 0
        let observer = NotificationCenter.default.addObserver(forName: RazerDevices.supportChanged, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        RazerDevices.applySupportList([0x00EA: []])
        RazerDevices.applySupportList([0x00EA: []])
        XCTAssertEqual(posts, 1)
    }
}

@MainActor
final class SupportListUpdaterTests: XCTestCase {
    nonisolated private static let suite = "SupportListUpdaterTests"
    private var defaults: UserDefaults { UserDefaults(suiteName: Self.suite)! }
    private let endpoint = URL(string: "https://reports.example/v1/support-list")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var applied: [[Int: Set<RazerFeature>]] = []

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: Self.suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    private final class Requests: @unchecked Sendable { var seen: [URLRequest] = [] }

    private func updater(version: String = "0.7.0", endpoint: URL?? = nil, requests: Requests = Requests(),
                         answer: @escaping @Sendable () throws -> (Data, Int)) -> SupportListUpdater {
        SupportListUpdater(defaults: defaults, endpoint: endpoint ?? self.endpoint, version: version,
                           transport: { request in
                               requests.seen.append(request)
                               let (data, status) = try answer()
                               return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                           },
                           apply: { [unowned self] in self.applied.append($0) })
    }

    private let good = listJSON(mice: #"{"pid":234,"link":"dongle","unverified":[]}"#)

    func testFetchesAppliesAndKeeps() async {
        let requests = Requests()
        let data = good
        await updater(requests: requests) { (data, 200) }.refreshIfDue(now: now)
        XCTAssertEqual(applied, [[0x00EA: []]])
        XCTAssertEqual(defaults.data(forKey: SupportListUpdater.listKey), good)
        let request = try? XCTUnwrap(requests.seen.first)
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertNil(request?.httpBody, "nothing about the Mac is sent")
        XCTAssertNil(request?.url?.query)
        XCTAssertTrue(request?.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("MacRazer/") == true)

        // A relaunch has it before any request.
        let offline = updater { throw URLError(.notConnectedToInternet) }
        applied = []
        offline.applyCached()
        XCTAssertEqual(applied, [[0x00EA: []]])
    }

    func testAsksOnlyWhenDue() async {
        let requests = Requests()
        let data = good
        let checker = updater(requests: requests) { (data, 200) }
        await checker.refreshIfDue(now: now)
        await checker.refreshIfDue(now: now.addingTimeInterval(SupportListUpdater.interval - 1))
        XCTAssertEqual(requests.seen.count, 1)
        await checker.refreshIfDue(now: now.addingTimeInterval(SupportListUpdater.interval))
        XCTAssertEqual(requests.seen.count, 2)
    }

    func testAFailureKeepsWhatIsThereAndStaysDue() async {
        defaults.set(good, forKey: SupportListUpdater.listKey)
        for answer in [{ throw URLError(.timedOut) }, { (Data("{}".utf8), 503) }, { (Data("nope".utf8), 200) }] as [@Sendable () throws -> (Data, Int)] {
            await updater(answer: answer).refreshIfDue(now: now)
        }
        XCTAssertEqual(applied, [])
        XCTAssertEqual(defaults.data(forKey: SupportListUpdater.listKey), good)
        XCTAssertNil(defaults.object(forKey: SupportListUpdater.fetchedKey))
    }

    /// An answer the build can't use waits `retryInterval`; no answer at all (offline) doesn't.
    func testARefusedAnswerBacksOffButOfflineDoesNot() async {
        let requests = Requests()
        let offline = updater(requests: requests) { throw URLError(.notConnectedToInternet) }
        await offline.refreshIfDue(now: now)
        await offline.refreshIfDue(now: now.addingTimeInterval(1))
        XCTAssertEqual(requests.seen.count, 2, "offline asks again on the next trigger")
        XCTAssertNil(defaults.object(forKey: SupportListUpdater.refusedKey))

        let refusedRequests = Requests()
        let newerSchema = Data(#"{"schema":2,"version":"0.7.0","commit":"x","mice":[]}"#.utf8)
        let refused = updater(requests: refusedRequests) { (newerSchema, 200) }
        await refused.refreshIfDue(now: now)
        await refused.refreshIfDue(now: now.addingTimeInterval(SupportListUpdater.retryInterval - 1))
        XCTAssertEqual(refusedRequests.seen.count, 1, "not on every popover open")
        await refused.refreshIfDue(now: now.addingTimeInterval(SupportListUpdater.retryInterval))
        XCTAssertEqual(refusedRequests.seen.count, 2)

        let data = good
        await updater { (data, 200) }.refreshIfDue(now: now.addingTimeInterval(2 * SupportListUpdater.retryInterval))
        XCTAssertNil(defaults.object(forKey: SupportListUpdater.refusedKey), "a good answer clears it")
    }

    func testAListForAnOlderAppIsDropped() async {
        defaults.set(good, forKey: SupportListUpdater.listKey)
        defaults.set(now, forKey: SupportListUpdater.fetchedKey)
        let newer = updater(version: "0.8.0") { throw URLError(.notConnectedToInternet) }
        newer.applyCached()
        XCTAssertEqual(applied, [], "this build's own table wins")
        XCTAssertNil(defaults.data(forKey: SupportListUpdater.listKey))
        XCTAssertNil(defaults.object(forKey: SupportListUpdater.fetchedKey), "so it asks straight away")

        let data = good
        await updater(version: "0.8.0") { (data, 200) }.refreshIfDue(now: now)
        XCTAssertEqual(applied, [[:]])
        XCTAssertNil(defaults.data(forKey: SupportListUpdater.listKey))
    }

    func testNoWorkerNoRequest() async {
        let requests = Requests()
        let data = good
        await updater(endpoint: .some(nil), requests: requests) { (data, 200) }.refreshIfDue(now: now)
        XCTAssertEqual(requests.seen.count, 0)
    }
}

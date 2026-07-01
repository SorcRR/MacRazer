// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class BatteryHistoryTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Fixed suite name (XCTest runs these serially in-process): a crashed run leaves at
        // most one orphaned plist, which the next run's setUp wipes — a UUID-per-run name
        // would accumulate orphans in ~/Library/Preferences instead.
        suiteName = "MacRazerTests-BatteryHistory"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeHistory(key: String = "test") -> BatteryHistory {
        BatteryHistory(deviceKey: key, directory: dir, defaults: defaults)
    }

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    /// Steady 1%/hour discharge sampled every 5 minutes for `hours`.
    private func feedSteadyDischarge(_ h: BatteryHistory, from start: Int, hours: Double, startingAt: Date? = nil) -> Date {
        let begin = startingAt ?? t0
        var t = begin
        let end = begin.addingTimeInterval(hours * 3600)
        while t <= end {
            let pct = start - Int(t.timeIntervalSince(begin) / 3600)
            h.record(percent: pct, charging: false, at: t)
            t = t.addingTimeInterval(300)
        }
        return t
    }

    func testSteadyDischargeRateAndEstimate() {
        let h = makeHistory()
        _ = feedSteadyDischarge(h, from: 100, hours: 4)
        XCTAssertEqual(h.currentRatePerHour ?? 0, 1.0, accuracy: 0.1)
        XCTAssertEqual(h.estimateHoursRemaining(currentPercent: 96) ?? 0, 96, accuracy: 10)
    }

    func testNoEstimateUntilConfidentTrend() {
        let h = makeHistory()
        h.record(percent: 100, charging: false, at: t0)
        h.record(percent: 100, charging: false, at: t0.addingTimeInterval(15))
        XCTAssertNil(h.estimateHoursRemaining(currentPercent: 100), "two flat samples are not a trend")
    }

    /// The "~19d left after a weekend away" bug: an idle gap's wall-clock time must not
    /// flatten the fitted slope...
    func testIdleGapTimeIsSplicedOutOfFit() {
        let h = makeHistory()
        let beforeGap = feedSteadyDischarge(h, from: 100, hours: 4) // ends ~96%
        // 60h offline, battery self-drains 2% during it.
        let afterGap = beforeGap.addingTimeInterval(60 * 3600)
        _ = feedSteadyDischarge(h, from: 94, hours: 4, startingAt: afterGap)
        let rate = h.currentRatePerHour ?? 0
        XCTAssertGreaterThan(rate, 0.7, "gap time counted into the fit would flatten the rate to ~0.1%/hr")
        // ...and the drop that happened DURING the gap must not steepen it either.
        XCTAssertLessThan(rate, 1.4, "gap drop landing on a compressed x-step would inflate the rate")
    }

    func testChargingKeepsWindowEmptyAndFinishesCycleOnce() {
        let h = makeHistory()
        var finishedCycles: [[BatterySample]] = []
        h.onCycleFinished = { finishedCycles.append($0) }
        let end = feedSteadyDischarge(h, from: 100, hours: 4)
        XCTAssertNotNil(h.cycleStartedAt)
        // Docked: repeated charging ticks.
        h.record(percent: 97, charging: true, at: end.addingTimeInterval(15))
        h.record(percent: 98, charging: true, at: end.addingTimeInterval(30))
        h.record(percent: 99, charging: true, at: end.addingTimeInterval(45))
        XCTAssertEqual(finishedCycles.count, 1, "one cycle end, not one per charging tick")
        XCTAssertNil(h.cycleStartedAt, "no discharge window while charging")
        XCTAssertTrue(h.samples.isEmpty)
        // First not-charging sample starts the new cycle.
        h.record(percent: 100, charging: false, at: end.addingTimeInterval(3600))
        XCTAssertEqual(h.cycleStartedPercent, 100)
    }

    func testUptickResetsCycleButPlusOneNoiseDoesNot() {
        let h = makeHistory()
        var finished = 0
        h.onCycleFinished = { _ in finished += 1 }
        h.record(percent: 90, charging: false, at: t0)
        h.record(percent: 91, charging: false, at: t0.addingTimeInterval(15)) // +1: tolerated
        XCTAssertEqual(finished, 0)
        h.record(percent: 93, charging: false, at: t0.addingTimeInterval(30)) // +2: reset
        XCTAssertEqual(finished, 1)
    }

    func testLongGapFiresObservationGapNotInterval() {
        let h = makeHistory()
        var intervals = 0, gaps = 0
        h.onInterval = { _, _, _ in intervals += 1 }
        h.onObservationGap = { gaps += 1 }
        h.record(percent: 90, charging: false, at: t0)
        h.record(percent: 90, charging: false, at: t0.addingTimeInterval(15))
        XCTAssertEqual(intervals, 1)
        h.record(percent: 89, charging: false, at: t0.addingTimeInterval(15 + 3600)) // 1h gap
        XCTAssertEqual(intervals, 1, "gap-spanning interval must not feed dwell learning")
        XCTAssertEqual(gaps, 1)
    }

    func testPersistenceRoundTripAndLegacyMigration() {
        let h = makeHistory()
        _ = feedSteadyDischarge(h, from: 100, hours: 1)
        h.saveNow()
        XCTAssertEqual(makeHistory().samples.count, h.samples.count)

        // Pre-envelope bare-array file must migrate (real user history survives upgrade).
        let legacy = [BatterySample(t: t0, pct: 90), BatterySample(t: t0.addingTimeInterval(60), pct: 89)]
        try! JSONEncoder().encode(legacy).write(to: dir.appendingPathComponent("battery-history-old.json"))
        let migrated = BatteryHistory(deviceKey: "old", directory: dir, defaults: defaults)
        XCTAssertEqual(migrated.samples.count, 2)
    }

    func testFormatDuration() {
        XCTAssertEqual(BatteryHistory.formatDuration(hours: 0.5), "30m")
        XCTAssertEqual(BatteryHistory.formatDuration(hours: 1.5), "1h 30m")
        XCTAssertEqual(BatteryHistory.formatDuration(hours: 25), "1d 1h")
        XCTAssertEqual(BatteryHistory.formatDuration(hours: -1), "0m")
    }

    func testDecimationPreservesShapeAndBounds() {
        let small = (0..<100).map { BatterySample(t: t0.addingTimeInterval(Double($0) * 15), pct: 100 - $0 / 2) }
        XCTAssertEqual(BatteryHistory.decimatedForDisplay(small).count, small.count, "small arrays pass through")

        // 10,000 samples with a brief deep dip that decimation must keep visible.
        var big = (0..<10_000).map { BatterySample(t: t0.addingTimeInterval(Double($0) * 15), pct: 80) }
        big[5_000] = BatterySample(t: big[5_000].t, pct: 20)
        let out = BatteryHistory.decimatedForDisplay(big)
        XCTAssertLessThanOrEqual(out.count, 602)
        XCTAssertEqual(out.first?.t, big.first?.t)
        XCTAssertEqual(out.last?.t, big.last?.t)
        XCTAssertTrue(out.contains { $0.pct == 20 }, "min-preserving: the dip must survive")
        XCTAssertEqual(out.map(\.t), out.map(\.t).sorted(), "chronological order preserved")
        XCTAssertEqual(Set(out.map(\.t)).count, out.count, "unique timestamps (chart id + hover)")
    }
}

final class ChargeCycleHistoryTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func samples(spanMinutes: Double, drop: Int, count: Int = 10) -> [BatterySample] {
        (0..<count).map { i in
            BatterySample(t: t0.addingTimeInterval(Double(i) * spanMinutes * 60 / Double(count - 1)),
                          pct: 100 - (drop * i) / (count - 1))
        }
    }

    func testNoiseCyclesAreRejected() {
        let h = ChargeCycleHistory(deviceKey: "t", directory: dir)
        h.recordFinishedCycle(samples: [])
        h.recordFinishedCycle(samples: samples(spanMinutes: 5, drop: 5))    // too short a span
        h.recordFinishedCycle(samples: samples(spanMinutes: 60, drop: 1))   // too small a drop
        h.recordFinishedCycle(samples: Array(samples(spanMinutes: 60, drop: 5).prefix(3))) // too few samples
        XCTAssertTrue(h.cycles.isEmpty)
    }

    func testRealCycleIsRecordedAndPersisted() {
        let h = ChargeCycleHistory(deviceKey: "t", directory: dir)
        h.recordFinishedCycle(samples: samples(spanMinutes: 120, drop: 10))
        XCTAssertEqual(h.cycles.count, 1)
        XCTAssertEqual(h.cycles[0].startPercent, 100)
        XCTAssertEqual(h.cycles[0].endPercent, 90)
        XCTAssertEqual(h.averageCycleDuration ?? 0, 120 * 60, accuracy: 1)
        XCTAssertEqual(ChargeCycleHistory(deviceKey: "t", directory: dir).cycles.count, 1)
    }

    func testRollingWindowCapsAt30() {
        let h = ChargeCycleHistory(deviceKey: "t", directory: dir)
        for _ in 0..<35 { h.recordFinishedCycle(samples: samples(spanMinutes: 120, drop: 10)) }
        XCTAssertEqual(h.cycles.count, 30)
    }
}

final class VersionedFileStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testRoundTripAndVersionMismatch() {
        let store = VersionedFileStore<[Int]>(filename: "t.json", version: 1, directory: dir)
        store.saveNow([1, 2, 3])
        XCTAssertEqual(store.load(), [1, 2, 3])
        let v2 = VersionedFileStore<[Int]>(filename: "t.json", version: 2, directory: dir)
        XCTAssertNil(v2.load(), "version mismatch must discard, not misparse")
    }

    func testLegacyMigrationFlag() {
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! JSONEncoder().encode([4, 5]).write(to: dir.appendingPathComponent("bare.json"))
        let store = VersionedFileStore<[Int]>(filename: "bare.json", version: 1, directory: dir)
        XCTAssertNil(store.load(), "bare files are rejected unless migration is requested")
        XCTAssertEqual(store.load(migratingLegacy: true), [4, 5])
    }

    func testCorruptFileLoadsAsNil() {
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data("{\"version\": 1, \"payl".utf8).write(to: dir.appendingPathComponent("cut.json"))
        let store = VersionedFileStore<[Int]>(filename: "cut.json", version: 1, directory: dir)
        XCTAssertNil(store.load(migratingLegacy: true))
    }

    func testThrottledSaveSkipsWithinInterval() {
        let store = VersionedFileStore<[Int]>(filename: "t.json", version: 1, saveInterval: 30, directory: dir)
        store.save([1])          // first save always writes (lastSaveAt starts distantPast)
        store.save([2])          // within 30s → skipped
        XCTAssertEqual(store.load(), [1])
        store.saveNow([3])       // bypasses the throttle
        XCTAssertEqual(store.load(), [3])
    }
}

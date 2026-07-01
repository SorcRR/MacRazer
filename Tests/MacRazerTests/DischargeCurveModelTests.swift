// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class DischargeCurveModelTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeModel() -> DischargeCurveModel {
        DischargeCurveModel(modelKey: "test", directory: dir)
    }

    /// Walk the model through an observed discharge: arrive at `percent` (watched drop into
    /// it), dwell `dwell` seconds in poll-interval ticks, then drop out of it.
    private func traverse(_ model: DischargeCurveModel, percent: Int, dwell: TimeInterval, tick: TimeInterval = 15) {
        var remaining = dwell
        while remaining > 0 {
            model.record(fromPercent: percent, toPercent: percent, duration: min(tick, remaining))
            remaining -= tick
        }
        model.record(fromPercent: percent, toPercent: percent - 1, duration: tick)
    }

    /// The original bug: counting poll ticks instead of traversals collapsed the mean to the
    /// poll interval (~15s) instead of the real dwell (~18min on the plateau).
    func testMeanIsDwellPerTraversalNotPerTick() {
        let model = makeModel()
        // Watched arrival at 90 (drop from 91), then 30 minutes of flat 15s ticks at 90.
        model.record(fromPercent: 91, toPercent: 90, duration: 15)
        traverse(model, percent: 90, dwell: 30 * 60)
        let bucket = model.buckets[90]
        XCTAssertEqual(bucket.count, 1, "one completed traversal, not one count per tick")
        XCTAssertEqual(bucket.mean ?? 0, 30 * 60 + 15, accuracy: 20,
                       "mean must be the full dwell, not the poll interval")
    }

    func testEstimateUsesLearnedDwell() {
        let model = makeModel()
        // Two traversals (minSamplesToTrust) of 10 minutes at each percent 5...1.
        for _ in 0..<2 {
            model.record(fromPercent: 6, toPercent: 5, duration: 15)
            for pct in stride(from: 5, through: 1, by: -1) {
                traverse(model, percent: pct, dwell: 600)
            }
            model.observationInterrupted() // cycle boundary between the two passes
        }
        let hours = model.estimateHoursRemaining(currentPercent: 5, fallbackRatePerHour: nil)
        XCTAssertNotNil(hours)
        // 5 buckets × ~615s ≈ 0.85h
        XCTAssertEqual(hours ?? 0, 5 * 615 / 3600, accuracy: 0.1)
    }

    func testUnwatchedEntryDoesNotCommit() {
        let model = makeModel()
        // No watched arrival (fresh model = app relaunch): dwell then drop must NOT count.
        traverse(model, percent: 80, dwell: 120)
        XCTAssertEqual(model.buckets[80].count, 0,
                       "front-truncated dwell (entry never observed) must not commit")
        // But the drop's destination is now watched: the next full dwell counts.
        traverse(model, percent: 79, dwell: 300)
        XCTAssertEqual(model.buckets[79].count, 1)
    }

    func testInterveningPercentsCommitOnMultiPercentDrop() {
        let model = makeModel()
        model.record(fromPercent: 51, toPercent: 50, duration: 15) // watched arrival at 50
        model.record(fromPercent: 50, toPercent: 47, duration: 30) // steep drop through 48/49
        // 48 and 49 were entered AND left inside one observed interval → complete.
        XCTAssertEqual(model.buckets[49].count, 1)
        XCTAssertEqual(model.buckets[48].count, 1)
        XCTAssertEqual(model.buckets[50].count, 1) // watched entry + watched exit
        XCTAssertEqual(model.buckets[47].count, 0) // still dwelling there
    }

    func testJitterReentryDoesNotMintExtraTraversals() {
        let model = makeModel()
        model.record(fromPercent: 58, toPercent: 57, duration: 15) // 58 unwatched → no commit
        traverse(model, percent: 57, dwell: 300)                    // 57 commits (count 1)
        XCTAssertEqual(model.buckets[57].count, 1)
        // Gauge flickers back up to 57... (rising interval ignored), then drops again.
        model.record(fromPercent: 56, toPercent: 57, duration: 15) // rising: ignored
        model.record(fromPercent: 57, toPercent: 56, duration: 15) // re-entry wasn't watched
        XCTAssertEqual(model.buckets[57].count, 1, "flicker must not double-count the dwell")
    }

    func testObservationInterruptedDiscardsOpenDwell() {
        let model = makeModel()
        model.record(fromPercent: 61, toPercent: 60, duration: 15)
        model.record(fromPercent: 60, toPercent: 60, duration: 600) // 10 min open dwell
        model.observationInterrupted() // charge started / gap / device swap
        model.record(fromPercent: 60, toPercent: 59, duration: 15)
        XCTAssertEqual(model.buckets[60].count, 0,
                       "dwell interrupted mid-observation must be discarded, not committed short")
    }

    func testPersistenceRoundTripAndLegacyDiscard() {
        let model = makeModel()
        model.record(fromPercent: 91, toPercent: 90, duration: 15)
        traverse(model, percent: 90, dwell: 300)
        model.saveNow()
        let reloaded = makeModel()
        XCTAssertEqual(reloaded.buckets[90].count, 1)
        XCTAssertEqual(reloaded.buckets[90].totalSeconds, model.buckets[90].totalSeconds)

        // A v1 (pre-envelope bare array) file counted ticks — corrupt data, must be discarded.
        let legacy = try! JSONEncoder().encode(Array(repeating: DischargeBucket(totalSeconds: 900, count: 60), count: 101))
        try! legacy.write(to: dir.appendingPathComponent("discharge-curve-legacy.json"))
        let migrated = DischargeCurveModel(modelKey: "legacy", directory: dir)
        XCTAssertEqual(migrated.buckets[50].count, 0, "v1 tick-counted data must not migrate")
    }

    func testEstimateFallsBackToRateForUnlearnedBuckets() {
        let model = makeModel()
        // No learned data at all: estimate = percent / rate.
        let hours = model.estimateHoursRemaining(currentPercent: 50, fallbackRatePerHour: 2)
        XCTAssertEqual(hours ?? 0, 25, accuracy: 0.01)
        // No data AND no rate → nil; zero percent → 0.
        XCTAssertNil(model.estimateHoursRemaining(currentPercent: 50, fallbackRatePerHour: nil))
        XCTAssertEqual(model.estimateHoursRemaining(currentPercent: 0, fallbackRatePerHour: nil), 0)
    }
}

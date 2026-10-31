// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Running mean of how long the battery actually dwells at each percent (0-100), learned from
/// real discharge history. A firmware fuel gauge's reported percent does not necessarily
/// map linearly to time for every battery chemistry and device. A single %/hour rate (the
/// generic model `BatteryHistory` uses for most mice) can't represent that shape; this can,
/// because each percent gets its own learned dwell time instead of one shared rate.
struct DischargeBucket: Codable {
    var totalSeconds: Double = 0
    /// Completed traversals: how many times a discharge has passed *through and out of* this
    /// percent, observed end-to-end. NOT poll ticks — dividing by ticks would make `mean`
    /// converge on the poll interval (~15s) instead of the real dwell time (~18min on the
    /// plateau), collapsing the whole-curve estimate to `percent × poll interval`.
    var count: Int = 0
    var mean: Double? { count > 0 ? totalSeconds / Double(count) : nil }
}

struct DischargeCurveEstimate {
    let hoursRemaining: Double
    let isFullyTrusted: Bool
}

final class DischargeCurveModel {
    /// Index 0...100 = percent. 101 buckets, always fully allocated (some just empty).
    private(set) var buckets: [DischargeBucket]
    /// Dwell seconds accumulated at each percent for the current, still-open traversal.
    /// Committed into `buckets` only once the discharge drops out of that percent.
    private var pendingSeconds = [Double](repeating: 0, count: 101)
    /// Whether we actually watched the battery *arrive* at each percent (a drop into it
    /// within one observed interval). A dwell whose start wasn't seen — app launch, an
    /// offline gap, a device swap, or a noise flicker whose rising edge is ignored — is
    /// front-truncated: committing it as a full traversal would bias the mean low, the same
    /// corruption class this model exists to avoid. Neither this nor `pendingSeconds` is
    /// persisted: an open traversal interrupted by a relaunch is discarded, never
    /// committed short.
    private var entryObserved = [Bool](repeating: false, count: 101)
    /// Below this many completed traversals (full discharge passes through the percent), a
    /// bucket falls back to the rate-derived estimate instead of trusting its own
    /// (still-noisy) mean.
    private let minSamplesToTrust = 2
    /// v2: `count` counts completed traversals. The pre-envelope v1 files counted poll ticks,
    /// which is exactly the bug this version fixes — that data is corrupt under the new math,
    /// so it is discarded (fresh re-learn), not migrated.
    private let store: VersionedFileStore<[DischargeBucket]>

    init(modelKey: String, directory: URL? = nil) {
        store = VersionedFileStore(filename: "discharge-curve-\(modelKey).json", version: 2,
                                   directory: directory)
        buckets = Array(repeating: DischargeBucket(), count: 101)
        if let decoded = store.load(), decoded.count == buckets.count {
            buckets = decoded
        }
    }

    /// Distributes `duration` across every percent point crossed while discharging
    /// (`fromPercent > toPercent`) — splitting evenly rather than crediting it all to
    /// `fromPercent` matters near steep drops, where one poll interval can skip several
    /// percent points at once. A flat interval accrues to its percent's open traversal. A
    /// rising interval (sensor noise — doesn't trigger `BatteryHistory`'s cycle reset) is
    /// ignored, since there's no clean way to attribute it.
    func record(fromPercent: Int, toPercent: Int, duration: TimeInterval) {
        guard duration > 0, duration.isFinite else { return }
        guard fromPercent >= toPercent, fromPercent >= 0, fromPercent <= 100, toPercent >= 0 else { return }
        if fromPercent == toPercent {
            pendingSeconds[fromPercent] += duration
            return
        }
        let share = duration / Double(fromPercent - toPercent)
        var committedAny = false
        for pct in (toPercent + 1)...fromPercent {
            // Percents strictly inside the interval were entered AND left within this one
            // observed interval, so their traversal is complete by construction. The
            // boundary percent's dwell began earlier — it only counts if its start was
            // actually seen (see `entryObserved`).
            if pct < fromPercent || entryObserved[fromPercent] {
                buckets[pct].totalSeconds += pendingSeconds[pct] + share
                buckets[pct].count += 1
                committedAny = true
            }
            pendingSeconds[pct] = 0
            entryObserved[pct] = false
        }
        entryObserved[toPercent] = true // we just watched the battery arrive here
        if committedAny { store.save(buckets) }
    }

    /// The continuous observation stream broke: a charge started (cycle reset), an
    /// offline/sleep gap, or a device swap. Every open dwell is now a partial observation
    /// and the next entry into the current percent wasn't seen — drop the open state so
    /// front-truncated dwells can't commit as complete traversals. Learned buckets persist;
    /// observation resumes with the next watched percent-to-percent drop.
    func observationInterrupted() {
        pendingSeconds = [Double](repeating: 0, count: 101)
        entryObserved = [Bool](repeating: false, count: 101)
    }

    /// Unconditional write, bypassing the save throttle — for app termination.
    func saveNow() {
        store.saveNow(buckets)
    }

    /// Sum of learned (or rate-derived fallback) dwell time for every bucket from
    /// `currentPercent` down to 1. A provisional caller may use one observed traversal for a
    /// bucket; otherwise under-sampled means retain the legacy fallback behavior used by Cobra.
    func estimate(currentPercent: Int, fallbackRatePerHour: Double?,
                  allowProvisionalMeans: Bool = false) -> DischargeCurveEstimate? {
        guard currentPercent > 0 else {
            return DischargeCurveEstimate(hoursRemaining: 0, isFullyTrusted: true)
        }
        let fallbackSecondsPerPercent = fallbackRatePerHour.map { 3600 / $0 }
        var totalSeconds = 0.0
        var isFullyTrusted = true
        for pct in 1...min(currentPercent, 100) {
            let bucket = buckets[pct]
            if let mean = bucket.mean, bucket.count >= minSamplesToTrust {
                totalSeconds += mean
            } else if allowProvisionalMeans, let mean = bucket.mean {
                totalSeconds += mean
                isFullyTrusted = false
            } else if let fallback = fallbackSecondsPerPercent {
                totalSeconds += fallback
                isFullyTrusted = false
            } else if let mean = bucket.mean {
                // Preserve the original under-sampled fallback when no scalar rate exists.
                totalSeconds += mean
                isFullyTrusted = false
            } else {
                return nil // this bucket has neither learned dwell data nor a fallback
            }
        }
        return DischargeCurveEstimate(hoursRemaining: totalSeconds / 3600,
                                      isFullyTrusted: isFullyTrusted)
    }

    func estimateHoursRemaining(currentPercent: Int, fallbackRatePerHour: Double?) -> Double? {
        estimate(currentPercent: currentPercent, fallbackRatePerHour: fallbackRatePerHour)?.hoursRemaining
    }
}

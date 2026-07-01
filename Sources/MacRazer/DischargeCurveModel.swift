// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Running mean of how long the battery actually dwells at each percent (0-100), learned from
/// real discharge history. A Li-ion cell's voltage — and so a firmware fuel gauge's reported
/// percent — isn't linear with time: there's a long flat plateau through most of the
/// discharge, then steep drops near full and near empty. A single %/hour rate (the generic
/// model `BatteryHistory` uses for every other mouse) can't represent that shape; this can,
/// because each percent gets its own learned dwell time instead of one shared rate.
struct DischargeBucket: Codable {
    var totalSeconds: Double = 0
    var count: Int = 0
    var mean: Double? { count > 0 ? totalSeconds / Double(count) : nil }
}

final class DischargeCurveModel {
    private let url: URL
    /// Index 0...100 = percent. 101 buckets, always fully allocated (some just empty).
    private(set) var buckets: [DischargeBucket]
    /// Below this many samples, a bucket falls back to the rate-derived estimate instead of
    /// trusting its own (still-noisy) mean.
    private let minSamplesToTrust = 2
    /// `record()` fires on every poll tick while discharging — throttle the disk write rather
    /// than re-encoding and rewriting all 101 buckets every 4-15s for what's typically a few
    /// bytes of actual change. Losing a few seconds of the latest bucket update on an unclean
    /// quit is an acceptable trade.
    private var lastSaveAt = Date.distantPast
    private let saveInterval: TimeInterval = 30

    init(modelKey: String) {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacRazer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("discharge-curve-\(modelKey).json")
        buckets = Array(repeating: DischargeBucket(), count: 101)
        load()
    }

    /// Distributes `duration` across every percent point crossed while discharging
    /// (`fromPercent > toPercent`) — splitting evenly rather than crediting it all to
    /// `fromPercent` matters near steep drops, where one poll interval can skip several
    /// percent points at once. A flat interval credits its single bucket in full. A rising
    /// interval (sensor noise — doesn't trigger `BatteryHistory`'s cycle reset) is ignored,
    /// since there's no clean way to attribute it.
    func record(fromPercent: Int, toPercent: Int, duration: TimeInterval) {
        guard duration > 0, duration.isFinite else { return }
        guard fromPercent >= toPercent, fromPercent >= 0, fromPercent <= 100, toPercent >= 0 else { return }
        if fromPercent == toPercent {
            add(duration, toBucket: fromPercent)
        } else {
            let span = fromPercent - toPercent
            let share = duration / Double(span)
            for pct in (toPercent + 1)...fromPercent { add(share, toBucket: pct) }
        }
        let now = Date()
        guard now.timeIntervalSince(lastSaveAt) >= saveInterval else { return }
        lastSaveAt = now
        save()
    }

    private func add(_ seconds: Double, toBucket pct: Int) {
        guard buckets.indices.contains(pct) else { return }
        buckets[pct].totalSeconds += seconds
        buckets[pct].count += 1
    }

    /// Sum of learned (or rate-derived fallback) dwell time for every bucket from
    /// `currentPercent` down to 1, in hours. nil only if there's no curve data for any bucket
    /// in range AND no fallback rate — mirrors `BatteryHistory.estimateHoursRemaining`'s
    /// "no data yet" case.
    func estimateHoursRemaining(currentPercent: Int, fallbackRatePerHour: Double?) -> Double? {
        guard currentPercent > 0 else { return 0 }
        let fallbackSecondsPerPercent = fallbackRatePerHour.map { 3600 / $0 }
        var totalSeconds = 0.0
        var hasAnyData = false
        for pct in 1...min(currentPercent, 100) {
            let bucket = buckets[pct]
            if let mean = bucket.mean, bucket.count >= minSamplesToTrust {
                totalSeconds += mean
                hasAnyData = true
            } else if let fallback = fallbackSecondsPerPercent {
                totalSeconds += fallback
            } else if let mean = bucket.mean {
                // No fallback rate available at all — better than nothing even under-sampled.
                totalSeconds += mean
                hasAnyData = true
            } else {
                return nil // this bucket has neither learned data nor a fallback rate
            }
        }
        guard hasAnyData || fallbackSecondsPerPercent != nil else { return nil }
        return totalSeconds / 3600
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([DischargeBucket].self, from: data),
              decoded.count == buckets.count else { return }
        buckets = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(buckets) else { return }
        try? data.write(to: url)
    }
}

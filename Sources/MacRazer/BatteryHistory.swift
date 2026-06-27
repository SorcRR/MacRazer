// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Persists battery %/timestamp samples and derives a time-until-empty estimate.
///
/// No device API exists for this — we log samples and fit a discharge rate. Accuracy is
/// poor with little data and improves over time. Always present the result as an estimate.
struct BatterySample: Codable {
    let t: Date
    let pct: Int
}

final class BatteryHistory {
    private let url: URL
    private(set) var samples: [BatterySample] = []

    /// Keep a bounded window so a single charge cycle dominates the fit.
    private let maxSamples = 500
    /// Per-device key (e.g. the PID hex) so each mouse keeps its own history + learned rate.
    private let deviceKey: String

    /// Fired with the about-to-be-cleared samples on every reset (a charge event, or while
    /// charging continues — each poll tick re-clears `samples`, so this can fire repeatedly with
    /// a near-empty array during a single charge session). Callers must filter noise themselves;
    /// `ChargeCycleHistory.recordFinishedCycle` does this via its span/drop thresholds.
    var onCycleFinished: (([BatterySample]) -> Void)?

    init(deviceKey: String) {
        self.deviceKey = deviceKey
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacRazer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("battery-history-\(deviceKey).json")
        load()
    }

    func record(percent: Int, charging: Bool) {
        // A charge event invalidates the discharge trend — reset the window on an uptick.
        let isReset = (samples.last.map { percent > $0.pct + 1 } ?? false) || charging
        if isReset {
            if !samples.isEmpty { onCycleFinished?(samples) }
            samples.removeAll()
        }
        samples.append(BatterySample(t: Date(), pct: percent))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        save()
    }

    /// Time the current discharge cycle started (the oldest sample since the last reset), or
    /// nil if there's no data yet.
    var cycleStartedAt: Date? { samples.first?.t }

    /// The discharge rate currently in effect (session fit if confident, else the persisted
    /// learned rate), exposed for display alongside the formatted estimate.
    var currentRatePerHour: Double? { sessionRatePerHour() ?? learnedRatePerHour }

    /// Persisted discharge rate (%/hour), learned across sessions AND charge cycles so the
    /// estimate is available immediately on launch / after a recharge instead of re-deriving
    /// from scratch each time.
    private var learnedRatePerHour: Double? {
        get { UserDefaults.standard.object(forKey: "learnedDischargeRate-\(deviceKey)") as? Double }
        set { UserDefaults.standard.set(newValue, forKey: "learnedDischargeRate-\(deviceKey)") }
    }

    /// Hours remaining. Prefers a fresh per-session slope (and folds it into the learned rate);
    /// otherwise falls back to the persisted learned rate.
    func estimateHoursRemaining(currentPercent: Int) -> Double? {
        if let rate = sessionRatePerHour() {
            // Blend the observed rate into the long-term learned rate (EMA), then use it.
            let blended = learnedRatePerHour.map { 0.8 * $0 + 0.2 * rate } ?? rate
            learnedRatePerHour = min(max(blended, 0.05), 60)
            return Double(currentPercent) / rate
        }
        if let rate = learnedRatePerHour, rate > 0 {
            return Double(currentPercent) / rate
        }
        return nil
    }

    /// Linear least-squares fit of the current samples → discharge rate in %/hour (positive),
    /// or nil until there's a confident downward trend.
    private func sessionRatePerHour() -> Double? {
        guard samples.count >= 4 else { return nil }
        let span = samples.last!.t.timeIntervalSince(samples.first!.t)
        guard span >= 900 else { return nil } // need at least 15 min of data

        // Require a real, measured discharge before trusting the slope (coarse ~1%/hour drain).
        let drop = Double(samples.first!.pct - samples.last!.pct)
        guard drop >= 2 else { return nil }

        let t0 = samples.first!.t.timeIntervalSince1970
        let xs = samples.map { $0.t.timeIntervalSince1970 - t0 } // seconds
        let ys = samples.map { Double($0.pct) }
        let n = Double(xs.count)
        let sumX = xs.reduce(0, +), sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).map(*).reduce(0, +)
        let sumXX = xs.map { $0 * $0 }.reduce(0, +)
        let denom = n * sumXX - sumX * sumX
        guard denom != 0 else { return nil }

        let slope = (n * sumXY - sumX * sumY) / denom // % per second
        guard slope < 0 else { return nil }           // not discharging (flat/charging)
        let ratePerHour = -slope * 3600.0
        guard ratePerHour.isFinite, ratePerHour > 0, ratePerHour < 60 else { return nil }
        return ratePerHour
    }

    /// Human-readable "~Xh Ym" / "~Xd Yh" string, or nil.
    func estimateString(currentPercent: Int) -> String? {
        guard let hours = estimateHoursRemaining(currentPercent: currentPercent) else { return nil }
        return "~\(Self.formatDuration(hours: hours)) left (est.)"
    }

    /// "Xd Yh" past a day, "Xh Ym" past an hour, else "Xm" — used for every duration-based stat
    /// (estimate, time-since-charge, average cycle length) so long spans don't render as e.g. "39h 0m".
    static func formatDuration(hours: Double) -> String {
        let totalMinutes = max(0, Int(hours * 60))
        let d = totalMinutes / 1440, h = (totalMinutes % 1440) / 60, m = totalMinutes % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([BatterySample].self, from: data) else { return }
        samples = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url)
    }
}

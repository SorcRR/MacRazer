// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Persists battery %/timestamp samples and derives a time-until-empty estimate.
///
/// No device API exists for this — we log samples and fit a discharge rate. Accuracy is
/// poor with little data and improves over time. Always present the result as an estimate.
struct BatterySample: Codable, Equatable {
    let t: Date
    let pct: Int
}

final class BatteryHistory {
    private let store: VersionedFileStore<[BatterySample]>
    private(set) var samples: [BatterySample] = []

    /// Keep a bounded window so a single charge cycle dominates the fit, but generous enough
    /// that the usage graph can show the *whole* cycle rather than just a recent slice — at the
    /// 15s connected-poll interval this covers a bit over 100 hours (~4 days), comfortably past
    /// any realistic single-charge duration for these mice.
    private let maxSamples = 25_000
    /// Per-device key (e.g. the PID hex) so each mouse keeps its own history + learned rate.
    private let deviceKey: String

    /// Fired with the about-to-be-cleared samples once per reset that actually had samples
    /// (a charge event or an uptick). Callers must filter noise themselves;
    /// `ChargeCycleHistory.recordFinishedCycle` does this via its span/drop thresholds.
    var onCycleFinished: (([BatterySample]) -> Void)?

    /// Fired with (previous percent, new percent, elapsed seconds) for every consecutive
    /// in-cycle sample pair — the raw signal `DischargeCurveModel` learns dwell times from.
    var onInterval: ((_ fromPercent: Int, _ toPercent: Int, _ duration: TimeInterval) -> Void)?

    /// Fired instead of `onInterval` when the gap between two in-cycle samples exceeds
    /// `maxIdleGap`: continuous observation broke, so the curve model must not treat what
    /// it sees next as a continuation of the dwell it was accumulating.
    var onObservationGap: (() -> Void)?

    /// Above this, a gap between two samples isn't real usage time — the mouse went to sleep,
    /// got disconnected, or the app was closed, none of which the device "remembers" as
    /// discharging once reconnected. Generous margin above both poll cadences (4-15s) so it
    /// never clips a real interval, but well short of any genuine offline gap. Used two ways:
    /// intervals longer than this are excluded from `DischargeCurveModel`'s dwell learning
    /// (a multi-hour disconnect would otherwise be credited as multi-hour dwell time at
    /// whatever percent it spans), and the session rate fit splices them out so idle time
    /// doesn't distort the slope.
    private let maxIdleGap: TimeInterval = 5 * 60

    init(deviceKey: String) {
        self.deviceKey = deviceKey
        store = VersionedFileStore(filename: "battery-history-\(deviceKey).json", version: 1)
        samples = store.load(migratingLegacy: true) ?? []
    }

    func record(percent: Int, charging: Bool) {
        let now = Date()
        // A charge event invalidates the discharge trend — reset the window on an uptick.
        let isReset = (samples.last.map { percent > $0.pct + 1 } ?? false) || charging
        if isReset {
            if !samples.isEmpty {
                onCycleFinished?(samples)
                samples.removeAll()
                // A cycle boundary is worth persisting immediately: the file is small right
                // after clearing, and losing the boundary would glue two cycles together.
                store.saveNow(samples)
            }
            // While charging, keep the window empty rather than appending charge-session
            // samples for the next tick to clear again — the discharge cycle starts at the
            // first not-charging sample, and the file isn't rewritten once per tick all
            // charge session long.
            if charging { return }
        } else if let last = samples.last {
            let elapsed = now.timeIntervalSince(last.t)
            if elapsed <= maxIdleGap {
                onInterval?(last.pct, percent, elapsed)
            } else {
                onObservationGap?()
            }
        }
        samples.append(BatterySample(t: now, pct: percent))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        store.save(samples) // throttled — see VersionedFileStore
    }

    /// Time the current discharge cycle started (the oldest sample since the last reset), or
    /// nil if there's no data yet.
    var cycleStartedAt: Date? { samples.first?.t }

    /// Battery percent at the start of the current discharge cycle — i.e. what it was charged
    /// to before we started consuming it again. Not necessarily 100%: any uptick (or a
    /// charging report) ends the previous cycle, full or not.
    var cycleStartedPercent: Int? { samples.first?.pct }

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
    /// otherwise falls back to the persisted learned rate. If `curveModel` is given (only for
    /// models with a learned per-percent discharge curve — see `DischargeCurveModel`) and it
    /// can produce an estimate, that wins over the plain `currentPercent / rate` projection,
    /// since a single rate can't represent a non-linear discharge curve. The rate is still
    /// computed/persisted exactly as before either way — it's also the curve model's own
    /// per-bucket fallback for percents it doesn't have data for yet.
    func estimateHoursRemaining(currentPercent: Int, curveModel: DischargeCurveModel? = nil) -> Double? {
        var rate: Double?
        if let session = sessionRatePerHour() {
            // Blend the observed rate into the long-term learned rate (EMA), then use it.
            let blended = learnedRatePerHour.map { 0.8 * $0 + 0.2 * session } ?? session
            learnedRatePerHour = min(max(blended, 0.05), 60)
            rate = session
        } else if let learned = learnedRatePerHour, learned > 0 {
            rate = learned
        }
        if let curveModel, let estimate = curveModel.estimateHoursRemaining(currentPercent: currentPercent, fallbackRatePerHour: rate) {
            return estimate
        }
        guard let rate else { return nil }
        return Double(currentPercent) / rate
    }

    /// Linear least-squares fit of the current samples → discharge rate in %/hour (positive),
    /// or nil until there's a confident downward trend.
    ///
    /// The fit sees *active* usage only: an idle/offline gap (mouse asleep or switched off,
    /// app closed, Mac asleep) contributes neither time nor drop. The gap's time is skipped
    /// on the x-axis, and the y-values after it are shifted up by whatever percent was lost
    /// during it (self-drain, fuel-gauge settle), splicing the active segments together.
    /// Keeping either side of a gap would corrupt the slope in opposite directions: counting
    /// the time turns a weekend away into "~19d left" on Monday; counting the drop lands the
    /// weekend's self-drain on a zero-length x-step and steepens the fit. Either error would
    /// also pollute the persisted learned rate through the EMA blend. The estimate therefore
    /// means "time remaining at active use", consistent with the dwell-based curve model,
    /// which excludes those same gaps.
    private func sessionRatePerHour() -> Double? {
        guard samples.count >= 4 else { return nil }

        var xs = [Double](repeating: 0, count: samples.count) // active seconds since first sample
        var ys = [Double](repeating: 0, count: samples.count) // percent, gap drops spliced out
        ys[0] = Double(samples[0].pct)
        var splice = 0.0
        for i in 1..<samples.count {
            let dt = samples[i].t.timeIntervalSince(samples[i - 1].t)
            if dt <= maxIdleGap {
                xs[i] = xs[i - 1] + dt
            } else {
                xs[i] = xs[i - 1]
                splice += Double(samples[i - 1].pct - samples[i].pct)
            }
            ys[i] = Double(samples[i].pct) + splice
        }
        guard xs.last! >= 900 else { return nil } // need at least 15 min of active data

        // Require a real, measured discharge before trusting the slope (coarse ~1%/hour drain).
        let drop = ys.first! - ys.last!
        guard drop >= 2 else { return nil }
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
    func estimateString(currentPercent: Int, curveModel: DischargeCurveModel? = nil) -> String? {
        guard let hours = estimateHoursRemaining(currentPercent: currentPercent, curveModel: curveModel) else { return nil }
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

    /// Unconditional write, bypassing the save throttle — for app termination, where the
    /// in-memory tail (up to ~30s of samples) would otherwise be lost.
    func saveNow() {
        store.saveNow(samples)
    }

    /// Downsampled copy for display. Swift Charts degrades badly past a few thousand marks,
    /// and the ~120pt-tall usage chart can't show more detail than a few hundred points
    /// anyway — but a full 4-day cycle at the 15s poll interval is up to 25,000 samples.
    /// Keeps each stride's min and max so short-lived dips survive, plus the exact first and
    /// last samples so the cycle's span stays intact.
    static func decimatedForDisplay(_ samples: [BatterySample], maxPoints: Int = 600) -> [BatterySample] {
        guard maxPoints >= 4, samples.count > maxPoints else { return samples }
        let strideSize = Int((Double(samples.count) / Double(maxPoints / 2)).rounded(.up))
        var out: [BatterySample] = []
        out.reserveCapacity(maxPoints + 2)
        out.append(samples[0])
        let lastIndex = samples.count - 1
        var i = 1
        while i < lastIndex {
            let end = min(i + strideSize, lastIndex)
            var lo = i, hi = i
            for j in i..<end {
                if samples[j].pct < samples[lo].pct { lo = j }
                if samples[j].pct > samples[hi].pct { hi = j }
            }
            if lo == hi {
                out.append(samples[lo])
            } else {
                out.append(samples[min(lo, hi)])
                out.append(samples[max(lo, hi)])
            }
            i = end
        }
        out.append(samples[lastIndex])
        return out
    }
}

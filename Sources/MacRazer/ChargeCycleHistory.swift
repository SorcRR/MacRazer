// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// A summary of one finished discharge cycle (from one charge to the next), used for the
/// cross-charge trend chart and the "average battery life per charge" stat.
struct ChargeCycleSummary: Codable {
    let start: Date
    let end: Date
    let startPercent: Int
    let endPercent: Int

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Persists a rolling log of past discharge cycles, fed by `BatteryHistory.onCycleFinished`
/// right before each cycle's raw samples are discarded.
final class ChargeCycleHistory {
    private let url: URL
    private(set) var cycles: [ChargeCycleSummary] = []
    private let maxCycles = 30

    init(deviceKey: String) {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacRazer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("charge-cycles-\(deviceKey).json")
        load()
    }

    /// Same noise thresholds as `BatteryHistory.sessionRatePerHour` — a real cycle needs a
    /// confident span and drop, not just a couple of stray samples before the next charge.
    func recordFinishedCycle(samples: [BatterySample]) {
        guard samples.count >= 4, let first = samples.first, let last = samples.last else { return }
        let span = last.t.timeIntervalSince(first.t)
        let drop = first.pct - last.pct
        guard span >= 900, drop >= 2 else { return }
        cycles.append(ChargeCycleSummary(start: first.t, end: last.t, startPercent: first.pct, endPercent: last.pct))
        if cycles.count > maxCycles { cycles.removeFirst(cycles.count - maxCycles) }
        save()
    }

    var averageCycleDuration: TimeInterval? {
        guard !cycles.isEmpty else { return nil }
        return cycles.map(\.duration).reduce(0, +) / Double(cycles.count)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ChargeCycleSummary].self, from: data) else { return }
        cycles = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cycles) else { return }
        try? data.write(to: url)
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import Charts

/// Battery usage sub-page: the current discharge curve, derived stats, and a cross-charge
/// trend chart. Reads only the `@Published` snapshots `MouseController` republishes on the
/// main queue (`batterySamples`, `pastCycles`, etc.) — never the underlying history objects,
/// which are owned and mutated on the `io` queue.
struct UsageGraphView: View {
    @ObservedObject var controller: MouseController
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BackButton(action: onBack)
                Text("Battery Usage").font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            currentCycleChart
            statsCard
            trendChart
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    // MARK: Current-cycle chart

    private var currentCycleChart: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("This charge", "bolt.fill")
                if controller.charging {
                    placeholder("Charging — usage tracking paused")
                } else if controller.batterySamples.count < 4 {
                    placeholder("Gathering data…")
                } else {
                    Chart(controller.batterySamples, id: \.t) { sample in
                        LineMark(x: .value("Time", sample.t), y: .value("Battery", sample.pct))
                            .foregroundStyle(Color.razerGreen)
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                    .frame(height: 120)
                }
            }
        }
    }

    // MARK: Stats

    private var statsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                statRow("Discharge rate", dischargeRateText)
                statRow("Estimated time remaining", remainingText)
                statRow("Time since last full charge", sinceChargeText)
                statRow("Average battery life per charge", averageLifeText)
            }
        }
    }

    private var dischargeRateText: String {
        guard let rate = controller.dischargeRatePerHour else { return "—" }
        return String(format: "%.1f%%/hr", rate)
    }

    private var remainingText: String {
        if controller.charging { return "Charging" }
        guard let pct = controller.batteryPercent, let rate = controller.dischargeRatePerHour, rate > 0 else { return "—" }
        return "~\(BatteryHistory.formatDuration(hours: Double(pct) / rate))"
    }

    private var sinceChargeText: String {
        // While charging, `cycleStartedAt` tracks the in-progress charge (it resets on every
        // poll tick until charging stops), so showing it here would read as a constantly
        // resetting "~0m" rather than the prior completed discharge.
        if controller.charging { return "Charging" }
        guard let start = controller.cycleStartedAt else { return "—" }
        return BatteryHistory.formatDuration(hours: Date().timeIntervalSince(start) / 3600)
    }

    private var averageLifeText: String {
        guard let avg = controller.averageCycleHours, !controller.pastCycles.isEmpty else {
            return "Not enough charge cycles tracked yet"
        }
        return "\(BatteryHistory.formatDuration(hours: avg)) average (\(controller.pastCycles.count) cycles)"
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
    }

    // MARK: Cross-charge trend chart

    private var trendChart: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Past charges", "clock.arrow.circlepath")
                if controller.pastCycles.isEmpty {
                    placeholder("No completed charge cycles tracked yet")
                } else {
                    // Bucketing by day would stack two same-day charges into one bar; use the
                    // exact end timestamp so each cycle gets its own bar.
                    Chart(controller.pastCycles, id: \.start) { cycle in
                        BarMark(x: .value("Charge", cycle.end), y: .value("Hours", cycle.duration / 3600))
                            .foregroundStyle(Color.razerGreen.opacity(0.75))
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .frame(height: 100)
                }
            }
        }
    }

    // MARK: Shared bits

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
    }
}

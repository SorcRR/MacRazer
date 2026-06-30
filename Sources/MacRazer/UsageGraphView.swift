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

    /// Sample/cycle currently under the pointer, used to draw the hover tooltip on each chart.
    @State private var hoveredSample: BatterySample?
    @State private var hoveredCycle: ChargeCycleSummary?

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
                HStack {
                    sectionLabel("This charge", "bolt.fill")
                    Spacer()
                    // Fixed slot next to the label, not anchored to the hovered point — an
                    // annotation positioned at the mark can overflow the chart's fixed-height
                    // frame and grow the enclosing card, which reads as the whole view jumping.
                    if let hovered = hoveredSample {
                        hoverLabel("\(hovered.pct)% · \(Self.timeFormatter.string(from: hovered.t))")
                    }
                }
                .frame(height: headerRowHeight)
                if controller.charging {
                    placeholder("Charging — usage tracking paused")
                } else if controller.batterySamples.count < 4 {
                    placeholder("Gathering data…")
                } else {
                    Chart(controller.batterySamples, id: \.t) { sample in
                        // Colored like the battery bar/gauge on the main page (low/mid/full).
                        // A plain per-point `.foregroundStyle(Color)` doesn't segment a
                        // LineMark in Swift Charts — every point ends up resolving to one
                        // style for the whole line. `foregroundStyle(by:)` + a matching
                        // `chartForegroundStyleScale` is what actually splits it into colored
                        // segments by value.
                        LineMark(x: .value("Time", sample.t), y: .value("Battery", sample.pct))
                            .foregroundStyle(by: .value("Level", Self.levelBand(sample.pct)))
                            .interpolationMethod(.monotone)
                        if hoveredSample?.t == sample.t {
                            RuleMark(x: .value("Time", sample.t))
                                .foregroundStyle(.secondary.opacity(0.25))
                            PointMark(x: .value("Time", sample.t), y: .value("Battery", sample.pct))
                                .foregroundStyle(batteryLevelColor(forPercent: sample.pct))
                                .symbolSize(50)
                        }
                    }
                    .chartForegroundStyleScale([
                        Self.lowBand: Color.batteryLow, Self.midBand: Color.batteryMid, Self.fullBand: Color.batteryFull,
                    ])
                    .chartLegend(.hidden)
                    .chartYScale(domain: 0...100)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                    .frame(height: 120)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            hoverCatcher(proxy: proxy, geo: geo) { date in
                                hoveredSample = controller.batterySamples.min {
                                    abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date))
                                }
                            } onEnd: {
                                hoveredSample = nil
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Level-band coloring (matches the battery bar's low/mid/full thresholds)

    private static let lowBand = "Low", midBand = "Mid", fullBand = "Full"
    private static func levelBand(_ pct: Int) -> String {
        switch pct {
        case ..<15: return lowBand
        case ..<40: return midBand
        default: return fullBand
        }
    }

    // MARK: Stats

    private var statsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                statRow("Discharge rate", dischargeRateText)
                statRow("Estimated time remaining", remainingText)
                statRow("Time since last charge", sinceChargeText)
                statRow("Average battery life per charge", averageLifeText)
            }
        }
    }

    private var dischargeRateText: String {
        guard let rate = controller.dischargeRatePerHour else { return "—" }
        return String(format: "%.1f%%/hr", rate)
    }

    private var remainingText: String {
        // Reuse `timeEstimate` (the same value the main battery card shows) rather than
        // recomputing percent/rate here — keeps the two displays from ever disagreeing, and
        // automatically picks up the learned discharge-curve estimate where one applies.
        guard let estimate = controller.timeEstimate else { return "—" }
        if estimate == "Charging" { return estimate }
        return estimate.replacingOccurrences(of: " left (est.)", with: "")
    }

    private var sinceChargeText: String {
        // While charging, `cycleStartedAt` tracks the in-progress charge (it resets on every
        // poll tick until charging stops), so showing it here would read as a constantly
        // resetting "~0m" rather than the prior completed discharge.
        if controller.charging { return "Charging" }
        guard let start = controller.cycleStartedAt else { return "—" }
        let duration = BatteryHistory.formatDuration(hours: Date().timeIntervalSince(start) / 3600)
        // The cycle starts wherever the last charge (full or partial) left off, not necessarily
        // 100% — show that starting level so the duration isn't read as "since it was full".
        guard let startPct = controller.cycleStartedPercent else { return duration }
        return "\(duration) (from \(startPct)%)"
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
                HStack {
                    sectionLabel("Past charges", "clock.arrow.circlepath")
                    Spacer()
                    if let hovered = hoveredCycle {
                        hoverLabel("\(BatteryHistory.formatDuration(hours: hovered.duration / 3600)) · \(Self.dayFormatter.string(from: hovered.end))")
                    }
                }
                .frame(height: headerRowHeight)
                if controller.pastCycles.isEmpty {
                    placeholder("No completed charge cycles tracked yet")
                } else {
                    // Bucketing by day would stack two same-day charges into one bar; use the
                    // exact end timestamp so each cycle gets its own bar.
                    Chart(controller.pastCycles, id: \.start) { cycle in
                        let isHovered = hoveredCycle?.start == cycle.start
                        BarMark(x: .value("Charge", cycle.end), y: .value("Hours", cycle.duration / 3600))
                            .foregroundStyle(Color.razerGreen.opacity(isHovered ? 1.0 : 0.75))
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .frame(height: 100)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            hoverCatcher(proxy: proxy, geo: geo) { date in
                                hoveredCycle = controller.pastCycles.min {
                                    abs($0.end.timeIntervalSince(date)) < abs($1.end.timeIntervalSince(date))
                                }
                            } onEnd: {
                                hoveredCycle = nil
                            }
                        }
                    }
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

    /// Fixed height for each chart's title row, so the hover label appearing/disappearing next
    /// to the section title never changes the row's height and shifts the chart below it.
    private let headerRowHeight: CGFloat = 16

    /// Small pill used by both charts' hover annotations.
    private func hoverLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    /// Transparent hit-test layer over a chart's plot area: tracks the pointer, converts its
    /// position to the chart's x-axis value, and reports it via `onMove` (nil x is ignored,
    /// since `value(atX:)` returns nil outside the plot area's bounds). `onEnd` fires when the
    /// pointer leaves so the caller can clear its hover state.
    private func hoverCatcher(proxy: ChartProxy, geo: GeometryProxy, onMove: @escaping (Date) -> Void, onEnd: @escaping () -> Void) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard let plotFrame = proxy.plotFrame else { return }
                    let origin = geo[plotFrame].origin
                    guard let date: Date = proxy.value(atX: location.x - origin.x) else { return }
                    onMove(date)
                case .ended:
                    onEnd()
                }
            }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}

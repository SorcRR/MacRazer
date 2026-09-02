// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// Control-Center-style tile: a rounded, lightly-frosted card on the dark popover. Shared by
/// every popover sub-page so the card style can't drift between them.
func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
}

/// A card with a small uppercase heading — the window-sized counterpart to `card`, shared by
/// the Settings and About windows so their sections can't drift apart. Slightly flatter and
/// tighter-cornered than `card`: those sit on the popover's dark material, these on a plain
/// window background where the popover's contrast would read as heavy.
func titledSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.6)
        content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
}

/// Small secondary-styled section heading used inside cards.
func sectionLabel(_ text: String, _ symbol: String) -> some View {
    Label(text, systemImage: symbol)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
}

/// The battery-percentage bands, in one place so every consumer agrees: this file's colour
/// helper, the percent readout in PopoverView, the usage chart's curve bands, and the
/// low-battery alert.
enum Battery {
    /// Below this the battery reads as "low" — red gauge/readout/curve, and the one
    /// `LowBatteryAlertPolicy` notification.
    static let lowThresholdPercent = 15
    /// Below this (and at or above `lowThresholdPercent`) is the amber middle band.
    static let midThresholdPercent = 40
    /// The alert re-arms only once the charge climbs back to here — deliberately above
    /// `lowThresholdPercent`. Without that gap, one garbage-but-accepted high reading (the
    /// poll state machine adopts a third consecutive outlier as the new baseline) would
    /// re-arm and let the next genuine low reading fire a duplicate alert.
    static let lowRearmPercent = 20
}

/// Battery-state color for a given percent — the same low/mid/full thresholds as the battery
/// card's level bar and gauge, shared so the usage graph's discharge curve matches it exactly.
func batteryLevelColor(forPercent pct: Int) -> Color {
    switch pct {
    case ..<Battery.lowThresholdPercent: return .batteryLow
    case ..<Battery.midThresholdPercent: return .batteryMid
    default: return .batteryFull
    }
}

/// Minimal left-aligned flow container: lays subviews in rows, wrapping when the next one
/// wouldn't fit the proposed width. SwiftUI has no built-in flow layout, and the profile
/// chips would otherwise overflow the fixed-width popover once a handful of profiles exist.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layoutRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.minY + $0.height } ?? 0
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layoutRows(maxWidth: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let natural = subviews[index].sizeThatFits(.unspecified)
                // Clamp to the container: a single over-wide subview (a chip with a long
                // profile name) truncates within bounds instead of drawing past the card.
                let width = min(natural.width, bounds.width)
                // Center each subview vertically within its row.
                let y = bounds.minY + row.minY + (row.height - natural.height) / 2
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      proposal: ProposedViewSize(width: width, height: natural.height))
                x += width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        var minY: CGFloat = 0
    }

    private func layoutRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var y: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let natural = subview.sizeThatFits(.unspecified)
            // Same clamp as placement, so row math matches what actually gets drawn.
            let size = CGSize(width: min(natural.width, maxWidth), height: natural.height)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && needed > maxWidth {
                current.minY = y
                y += current.height + spacing
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            current.minY = y
            rows.append(current)
        }
        return rows
    }
}

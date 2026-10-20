// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// Stable UI-only accents that make the onboard DPI stages easier to distinguish.
enum DPIStageAccent: Int, CaseIterable {
    case red
    case green
    case blue
    case teal
    case yellow

    static func forStage(at index: Int) -> DPIStageAccent {
        let cases = allCases
        let normalizedIndex = ((index % cases.count) + cases.count) % cases.count
        return cases[normalizedIndex]
    }

    var name: String {
        switch self {
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .teal: "Teal"
        case .yellow: "Yellow"
        }
    }

    var color: Color {
        switch self {
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .teal: .teal
        case .yellow: .yellow
        }
    }

    static func accessibilityLabel(value: Int, stageIndex: Int, active: Bool) -> String {
        let accent = forStage(at: stageIndex)
        let state = active ? ", active" : ""
        return "\(value) DPI, stage \(stageIndex + 1), \(accent.name)\(state)"
    }
}

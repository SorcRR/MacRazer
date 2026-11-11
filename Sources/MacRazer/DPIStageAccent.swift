// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// Stable UI-only accents that make the onboard DPI stages easier to distinguish. They don't
/// come from the mouse and aren't its stage LED colours; the hues are the lighting swatches'.
enum DPIStageAccent: Int, CaseIterable {
    case red
    case green
    case blue
    case cyan
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
        case .cyan: "Cyan"
        case .yellow: "Yellow"
        }
    }

    var color: Color {
        switch self {
        case .red: .swatchRed
        case .green: .razerGreen
        case .blue: .swatchBlue
        case .cyan: .swatchCyan
        case .yellow: .swatchYellow
        }
    }

    /// Text on a solid `color` fill: white only on the blue, which is too dark for black
    /// text; every other hue is light enough that dark text reads better than white.
    var onColor: Color {
        switch self {
        case .blue: .white
        case .green: .onRazerGreen
        case .red, .cyan, .yellow: .black
        }
    }

    /// The chip's spoken label. Whether it's the active stage is the `.isSelected` trait.
    static func accessibilityLabel(value: Int, stageIndex: Int) -> String {
        "\(value) DPI, stage \(stageIndex + 1), \(forStage(at: stageIndex).name)"
    }
}

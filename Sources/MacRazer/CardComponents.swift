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

/// Small secondary-styled section heading used inside cards.
func sectionLabel(_ text: String, _ symbol: String) -> some View {
    Label(text, systemImage: symbol)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
}

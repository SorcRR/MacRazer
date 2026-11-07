// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

// The text styles of the report windows (Test This Mouse, Report an Issue), shared so the two
// can't drift apart. Free functions like `card`, for the same reason: see `cardSurface`.

func reportTitle(_ text: String) -> some View {
    Text(text).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
}

func reportNote(_ text: String) -> some View {
    Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
}

func reportWarning(_ text: String) -> some View {
    Text(text).font(.system(size: 12)).foregroundStyle(Color.batteryMid).fixedSize(horizontal: false, vertical: true)
}

func reportRunning(_ text: String) -> some View {
    HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

/// A failed send's message, with the contact address in it as a link that starts `mail`.
func reportSendFailure(_ text: String, mail: URL) -> some View {
    var attributed = AttributedString(text)
    if let range = attributed.range(of: ProjectLinks.contactEmail) {
        attributed[range].link = mail
        attributed[range].underlineStyle = .single
    }
    return Text(attributed).font(.system(size: 12)).foregroundStyle(Color.batteryMid)
        .tint(Color.batteryMid)
        .fixedSize(horizontal: false, vertical: true)
}

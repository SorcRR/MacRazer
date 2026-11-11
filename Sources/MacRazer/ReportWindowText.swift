// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
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

/// A label and its value on one line, as the review card lists them.
@MainActor func reportRow(_ label: String, _ value: String, color: Color = .primary) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(label).foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text(value).foregroundStyle(color).multilineTextAlignment(.trailing)
    }
    .font(.system(size: 12))
}

/// A yes, no or not-sure question about what the person saw, as the lighting steps ask it.
@MainActor func reportQuestion(_ text: String, _ answer: Binding<DeviceTestModel.Answer?>) -> some View {
    card {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 12, weight: .medium))
            ChoiceButtons(selection: answer, options: [
                .init(value: .some(.yes), title: "Yes", icon: "checkmark.circle"),
                .init(value: .some(.no), title: "No", icon: "xmark.circle"),
                .init(value: .some(.unsure), title: "Not sure", icon: "questionmark.circle"),
            ])
        }
    }
}

func reportRunning(_ text: String) -> some View {
    HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

/// A failed send's message, with the contact address in it as a link that starts `mail`.
/// The text is selectable, and Copy email address is there too: on a Mac with no mail app set
/// up, the link opens nothing.
func reportSendFailure(_ text: String, mail: URL) -> some View {
    ReportSendFailure(text: text, mail: mail)
}

private struct ReportSendFailure: View {
    let text: String
    let mail: URL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attributed).font(.system(size: 12)).foregroundStyle(Color.batteryMid)
                .tint(Color.batteryMid)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(copied ? "Copied" : "Copy email address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ProjectLinks.contactEmail, forType: .string)
                copied = true
            }
            .buttonStyle(.link).font(.system(size: 11))
        }
    }

    private var attributed: AttributedString {
        var attributed = AttributedString(text)
        if let range = attributed.range(of: ProjectLinks.contactEmail) {
            attributed[range].link = mail
            attributed[range].underlineStyle = .single
        }
        return attributed
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// Shown on the launch after a crash: what happened, exactly what would be sent, and the
/// choice. Sending goes to the maintainer alone, so unlike the device test's GitHub issue it
/// can carry a reply email.
struct CrashReportView: View {
    @ObservedObject var model: CrashReportModel
    var onDone: () -> Void
    var onDontAskAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if model.state == .sent {
                Text("Thanks. The report was sent, and it helps more than you'd think.")
                    .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            } else {
                summary
                fields
            }
            footer
        }
        .padding(22)
        .frame(width: 440)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(Color.batteryMid.opacity(0.20))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.batteryMid)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("MacRazer quit unexpectedly").font(.system(size: 20, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        let ask = "Sending the crash report helps get it fixed."
        return model.count > 1 ? "It quit \(model.count) times. This is the most recent. \(ask)" : ask
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Version", "\(model.report.appVersion) (\(model.report.build))")
            row("macOS", model.report.os)
            if let exception = model.report.exception { row("Problem", exception) }
            if let place = model.whereItCrashed { row("Where", place) }
            DisclosureGroup("Show exactly what's sent") {
                ScrollView {
                    Text(CrashReportOutput.json(model.finalReport()))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 130)
            }
            .font(.system(size: 11))
            note("Your account name and anything that identifies this Mac are left out.")
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: Binding(get: { model.comment },
                                     set: { model.comment = String($0.prefix(DeviceReportOutput.maxComment)) }))
                .font(.system(size: 12))
                .frame(height: 54)
                .overlay(alignment: .topLeading) {
                    if model.comment.isEmpty {
                        Text("What were you doing when it quit? (optional)")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            TextField("Email, if you'd like a reply (optional)", text: $model.replyEmail)
                .textFieldStyle(.roundedBorder).controlSize(.small)
            if let problem = model.emailProblem { warning(problem) }
            if case .failed(let message) = model.state { warning(message) }
        }
    }

    private var footer: some View {
        HStack {
            if model.state != .sent {
                Button("Don't Ask Again", action: onDontAskAgain)
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.state == .sent {
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Don't Send", action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await model.send() }
                } label: {
                    if model.state == .sending { ProgressView().controlSize(.small) } else { Text("Send Report") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.razerGreen)
                .disabled(!model.canSend)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).lineLimit(2).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Color.batteryMid).fixedSize(horizontal: false, vertical: true)
    }
}

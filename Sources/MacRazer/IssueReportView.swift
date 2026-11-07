// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// "Report an Issue…": a description, an optional name and email, and Send. Laid out like
/// the device test, at its width, so the app's two report windows look like one family.
struct IssueReportView: View {
    @ObservedObject var model: IssueReportModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if model.sendState == .sent { sent } else { form }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Divider().padding(.vertical, 12)
            footer
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("What's going wrong?")
            note(model.canSend
                 ? "Send emails this to the maintainer. Nothing leaves your Mac until you press it."
                 : "Open a GitHub issue to tell the maintainer. Nothing leaves your Mac until you do.")
            VStack(alignment: .trailing, spacing: 2) {
                TextEditor(text: Binding(get: { model.description },
                                         set: { model.description = String($0.prefix(DeviceReportOutput.maxComment)) }))
                    .editorBox(placeholder: "Describe what happened and what you expected",
                               isEmpty: model.description.isEmpty, height: 110)
                // Verbatim: a localized number would print 2000 as "2.000" in some regions.
                Text(verbatim: "\(model.description.count) / \(DeviceReportOutput.maxComment)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            // Only Send carries the name and email, so without the Worker they'd go nowhere.
            if model.canSend {
                TextField("Your name (optional)", text: Binding(
                    get: { model.name },
                    set: { model.name = String($0.prefix(IssueReportOutput.maxName)) }))
                    .inputBox()
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Your email, if you'd like a reply (optional)", text: $model.replyEmail)
                        .inputBox()
                    if let problem = model.emailProblem {
                        warning(problem)
                    } else {
                        // The GitHub issue is public, so it leaves both out.
                        Text("Only Send includes your name and email, and only the maintainer sees them.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Include app and mouse details", isOn: $model.includeDetails)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                if model.includeDetails {
                    Text(IssueReportOutput.detailLines(model.details).joined(separator: "\n"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }
            if model.issueNeedsPaste {
                note("Your description is on your clipboard. Paste it into the issue before you submit it.")
            }
            switch model.sendState {
            case .sending: running("Sending…")
            case .failed(let outcome): warning(Self.sendFailure(outcome))
            case .idle, .sent: EmptyView()
            }
        }
    }

    static func sendFailure(_ outcome: DeviceReportSender.Outcome) -> String {
        switch outcome {
        case .tooMany: return "Too many reports from here today. Try again tomorrow, or open a GitHub issue instead."
        case .refused: return "The report server didn't accept this. Open a GitHub issue instead, please, and mention it."
        case .unavailable, .sent: return "Couldn't reach the report server. Check your connection and try again, or open a GitHub issue."
        }
    }

    // MARK: Thank you

    private var sent: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("Thank you")
            card {
                Text(model.emailProblem == nil && !model.replyEmail.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Your report is on its way to the maintainer, who can reply to \(model.replyEmail.trimmingCharacters(in: .whitespaces))."
                     : "Your report is on its way to the maintainer.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            // Only once it's sent: the person has just helped, and the ask is the footer's
            // quiet button, not a banner.
            note("MacRazer is free and built in spare time. If it saves you a trip to Windows, a tip keeps it going.")
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack {
            if model.sendState == .sent {
                Link(destination: ProjectLinks.tip) {
                    Label {
                        Text("Leave a tip")
                    } icon: {
                        // Multicolor: a bordered button tints a plain symbol with its label color.
                        Image(systemName: "heart.fill").symbolRenderingMode(.multicolor)
                            .foregroundStyle(Color(nsColor: .systemRed))
                    }
                }
                .buttonStyle(.bordered)
                .help("Opens MacRazer's Ko-fi page in your browser")
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction).buttonStyle(RazerProminentButtonStyle())
            } else {
                Button("Open GitHub issue") { model.openGitHubIssue() }
                    .disabled(!model.hasDescription)
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                // No Return shortcut: Return in the name or email field would send the report
                // before it's finished, and it can't be sent twice.
                if model.canSend {
                    Button("Send") { Task { await model.send() } }
                        .buttonStyle(RazerProminentButtonStyle())
                        .disabled(model.sendDisabled)
                }
            }
        }
        .controlSize(.large)
    }

    // MARK: Pieces

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Color.batteryMid).fixedSize(horizontal: false, vertical: true)
    }

    private func running(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

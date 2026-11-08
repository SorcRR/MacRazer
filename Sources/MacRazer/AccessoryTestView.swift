// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The lighting test for a keyboard or mousepad: what it does, the test itself with its two
/// questions, then the review and Send. See `AccessoryTestModel`.
struct AccessoryTestView: View {
    @ObservedObject var model: AccessoryTestModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(minHeight: 260, alignment: .topLeading)
            Divider().padding(.vertical, 12)
            footer
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .intro: intro
        case .lighting: lighting
        case .review:
            if model.sendState == .sent, let report = model.finalReport(), let verdict = report.verdict {
                sent(report, verdict)
            } else {
                review
            }
        }
    }

    // MARK: Screens

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            reportTitle("Test this \(model.noun)'s lighting")
            reportNote("MacRazer sets the lighting on your \(model.deviceName) with commands borrowed from a similar model. Nobody has tried them on this one yet. This short test checks they work, and sends us the result if you like.")
            card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What happens").font(.system(size: 12, weight: .medium))
                    Text(model.canShowRed
                         ? "Its lights go dark for three seconds, then turn red for three seconds. Then they go back to your brightness and to the lighting you set in MacRazer. You say what you saw."
                         : "Its lights go dark for three seconds, then come back to your brightness. You say what you saw.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.canShowRed {
                reportNote("Pick an effect for it in MacRazer first and the test can check colours too. Without one there's nothing to put back afterwards.")
            }
            if model.accessory?.synapseRunning == true {
                reportWarning("Razer Synapse is running and may change the lights during the test. Quitting it first gives a clearer result.")
            }
            reportNote("Nothing leaves your Mac until you choose to send it.")
        }
    }

    @ViewBuilder private var lighting: some View {
        VStack(alignment: .leading, spacing: 10) {
            reportTitle("Lighting")
            if model.running {
                reportRunning(model.canShowRed ? "Watch your \(model.noun): dark, then red…" : "Watch your \(model.noun): dark for a moment…")
            } else if let record = model.report?.lighting {
                if let data = record.data, data.dimShown {
                    question("Did the lights go dark for a moment?", $model.dimmed)
                    if data.redShown { question("Then did they turn red?", $model.turnedRed) }
                    reportNote(data.restored
                               ? "Everything has been put back."
                               : "Something couldn't be put back. Check its lighting in the popover.")
                } else {
                    reportWarning("Your \(model.noun) didn't take the lighting commands, so there was nothing to watch. Send the report anyway: it shows us which commands it refused.")
                }
            }
        }
    }

    private var review: some View {
        let report = model.finalReport()
        return VStack(alignment: .leading, spacing: 10) {
            reportTitle("Review")
            reportNote(model.canSend
                ? "Send emails this report to the maintainer. You can also copy it, or open a GitHub issue and paste it in."
                : "Copy the report, or open a GitHub issue and paste it in.")
            if let report, let verdict = report.verdict {
                card {
                    VStack(spacing: 4) {
                        row(report.device.name, String(format: "0x%04X", report.device.productID)
                            + (report.identify.data?.firmware.map { ", \($0)" } ?? ""))
                        if !verdict.passed.isEmpty { row("Worked", verdict.passed.joined(separator: ", "), color: .razerGreenText) }
                        if !verdict.failed.isEmpty { row("Didn't work", verdict.failed.joined(separator: ", "), color: .batteryMid) }
                        if !verdict.skipped.isEmpty { row("Not sure", verdict.skipped.joined(separator: ", ")) }
                    }
                }
                DisclosureGroup("Show full report") {
                    ScrollView {
                        Text(DeviceReportOutput.json(report, forPublic: true))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 110)
                }
                .font(.system(size: 11))
            }
            TextField("Name or GitHub handle to credit (optional)", text: $model.credit)
                .inputBox()
            if model.canSend {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Your email, if you'd like a reply (optional)", text: $model.replyEmail)
                        .inputBox()
                    if let problem = model.emailProblem {
                        reportWarning(problem)
                    } else {
                        Text("Only Send includes it, and only the maintainer sees it.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            TextEditor(text: Binding(get: { model.comment },
                                     set: { model.comment = String($0.prefix(DeviceReportOutput.maxComment)) }))
                .editorBox(placeholder: "Comments or feedback (optional)", isEmpty: model.comment.isEmpty)
            if model.copied { reportNote("Copied.") }
            if model.issueOpened { reportNote("The full report is on your clipboard. Paste it into the issue before you submit it.") }
            switch model.sendState {
            case .sending: reportRunning("Sending…")
            case .failed(let outcome):
                reportSendFailure(DeviceTestView.sendFailure(outcome), mail: ProjectLinks.mail(
                    subject: "MacRazer device report" + (report.map { ": \($0.device.name)" } ?? "")))
            case .idle, .sent: EmptyView()
            }
        }
    }

    private func sent(_ report: DeviceReport, _ verdict: DeviceTestVerdict) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            reportTitle("Thank you")
            card {
                Text(AccessoryTestModel.thankYou(verdict, noun: model.noun))
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            reportNote(report.replyEmail.map { "Your report is on its way to the maintainer, who can reply to \($0)." }
                       ?? "Your report is on its way to the maintainer.")
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack {
            switch model.stage {
            case .intro:
                Button("Cancel", action: onClose)
                Spacer()
                Button("Start") { model.start() }
                    .keyboardShortcut(.defaultAction).buttonStyle(RazerProminentButtonStyle())
                    .disabled(model.running || model.accessory?.isOpen != true)
            case .lighting:
                Button("Cancel", action: onClose).disabled(model.running)
                Spacer()
                Button("Next") { model.next() }
                    .keyboardShortcut(.defaultAction).buttonStyle(RazerProminentButtonStyle())
                    .disabled(model.running || !model.answered)
            case .review where model.sendState == .sent:
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction).buttonStyle(RazerProminentButtonStyle())
            case .review:
                Button("Back") { model.back() }
                Button("Copy") { model.copyReport() }
                Button("Open GitHub issue") { model.openGitHubIssue() }
                Spacer()
                // No default shortcut, as in the mouse test: Return in a field would send early.
                if model.canSend {
                    Button("Send") { model.send() }
                        .buttonStyle(RazerProminentButtonStyle())
                        .disabled(model.sendState == .sending || model.emailProblem != nil)
                } else {
                    Button("Done", action: onClose)
                }
            }
        }
        .controlSize(.large)
    }

    // MARK: Pieces

    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(color).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
    }

    private func question(_ text: String, _ answer: Binding<DeviceTestModel.Answer?>) -> some View {
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
}

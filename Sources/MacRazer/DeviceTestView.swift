// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The device test window. One screen per step; see `DeviceTestModel` for when each runs.
struct DeviceTestView: View {
    @ObservedObject var model: DeviceTestModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if DeviceTestModel.steps.contains(model.stage) { progress.padding(.bottom, 14) }
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(minHeight: 330, alignment: .topLeading)
            Divider().padding(.vertical, 12)
            footer
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: Progress

    /// One segment per test step, matching the "Step 2 of 6" count; Review fills them all.
    private var progress: some View {
        HStack(spacing: 4) {
            ForEach(Array(DeviceTestModel.steps.dropLast().enumerated()), id: \.offset) { _, step in
                Capsule()
                    .fill(step <= model.stage ? Color.razerGreen : Color.primary.opacity(0.15))
                    .frame(height: 4)
            }
        }
    }

    // MARK: Screens

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .intro: intro
        case .permission: permission
        case .identify: identify
        case .battery: battery
        case .dpi: dpi
        case .polling: polling
        case .lighting: lighting
        case .buttons: buttons
        case .review: review
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isKnownSupported {
                tag("Fully supported", color: .razerGreen)
                title("Your \(model.deviceName) is already supported")
                note("The test checks it really works on your mouse and firmware. Reports like this keep the supported list honest, and catch it early if a firmware update breaks something.")
            } else {
                title("Help support your \(model.deviceName)")
                note("About two minutes. Keep the mouse on, nearby, and connected by cable or dongle.")
            }
            card {
                Text("MacRazer talks to your mouse the way it does every day and records how it answers. Anything it changes is put back when each step ends, even if you stop half way.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            note("Nothing is sent anywhere unless you choose to at the end, and you'll see all of it first. Your mouse's serial number is never included.")
            switch model.blocker {
            case .noMouse?:
                warning("No Razer mouse is connected by cable or dongle right now. Connect it and press Start again.")
            case .bluetoothOnly(let name)?:
                warning("\(name) is connected over Bluetooth. The test needs the dongle or the cable, so switch it over and press Start again.")
            case nil:
                EmptyView()
            }
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("One permission first")
            note("MacRazer needs Input Monitoring to read your mouse's battery, DPI and lighting. Without it, only the first step can run.")
            card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Input Monitoring").font(.system(size: 13, weight: .semibold))
                    if model.needsRelaunch {
                        Text("Access is granted, but macOS only applies it after MacRazer restarts. It will reopen this test for you.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Grant it in the prompt, or in System Settings if you turned it down before.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !model.needsRelaunch {
                Button("Open System Settings") { model.openSettings() }.buttonStyle(.link)
            }
        }
    }

    private var identify: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("Identify", changes: false)
            note("What macOS reports, and which settings your mouse understands.")
            if model.running {
                running("Asking your mouse which settings it understands…")
            } else if let report = model.report {
                card {
                    VStack(spacing: 4) {
                        row("Name", report.device.name)
                        row("Product ID", String(format: "0x%04X", report.device.productID))
                        row("Firmware", report.identify.data?.firmware ?? "Unknown")
                        row("Interfaces", "\(report.device.interfaces.count)" + (report.device.controlInterface != nil ? ", control found" : ""))
                        row("Command format", commandFormat(report.identify.data))
                    }
                }
                outcomeRow("Identify", report.identify.outcome)
                VStack(alignment: .leading, spacing: 4) {
                    Text("How is it connected right now?").font(.system(size: 12))
                    Picker("", selection: $model.connection) {
                        Text("Not sure").tag(DeviceReport.Connection?.none)
                        Text("Cable").tag(DeviceReport.Connection?.some(.cable))
                        Text("Dongle").tag(DeviceReport.Connection?.some(.dongle))
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                }
            }
        }
    }

    private func commandFormat(_ data: DeviceReport.IdentifyData?) -> String {
        guard let data, let id = data.standardId else { return "No format answered" }
        let answered = data.standardAttempts.filter(\.answered).map { String(format: "0x%02X", $0.id) }
        return String(format: "0x%02X", id) + (answered.count > 1 ? " (also \(answered.dropFirst().joined(separator: ", ")))" : "")
    }

    private var battery: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("Battery", changes: false)
            note("Reads the level and whether it's charging.")
            if model.running {
                running("Reading the battery…")
            } else if let record = model.report?.battery {
                card {
                    VStack(spacing: 4) {
                        row("Battery", record.data?.percent.map { "\($0)%" } ?? "No answer")
                        row("Charging", record.data?.charging.map { $0 ? "Yes" : "No" } ?? "No answer")
                    }
                }
                outcomeRow("Battery", record.outcome)
                note("Plug in the cable now and check again to see charging detected.")
                Button("Check again") { Task { await model.runBattery() } }.controlSize(.small)
            }
        }
    }

    private var dpi: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("DPI", changes: true)
            note("Sets a value 50 away from yours, reads it back, then puts yours back.")
            if model.running {
                running("Testing DPI…")
            } else if let record = model.report?.dpi, record.data != nil || record.error != nil {
                card {
                    VStack(spacing: 4) {
                        row("Yours", record.data?.original.map(String.init) ?? "No answer")
                        row("Test, read back", "\(record.data?.test.map(String.init) ?? "–"), \(record.data?.readBack.map(String.init) ?? "–")")
                        row("Put back", record.data?.restored == true ? "Yes" : "No", color: record.data?.restored == true ? .razerGreen : .batteryMid)
                        if let stages = record.data?.stages { row("Stages", stages.map(String.init).joined(separator: " · ")) }
                        if let max = record.data?.maxProbe { row("Highest it kept", String(max)) }
                    }
                }
                outcomeRow("DPI", record.outcome)
            } else {
                Toggle(isOn: $model.maxProbe) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also find the highest DPI").font(.system(size: 12))
                        Text("Asks for the maximum and records what the mouse keeps. Your pointer may jump for a moment.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var polling: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("Polling rate", changes: true)
            note("Tries another rate, reads it back, then puts yours back.")
            if model.running {
                running("Testing the polling rate…")
            } else if let record = model.report?.polling, record.data != nil || record.error != nil {
                card {
                    VStack(spacing: 4) {
                        row("Yours", record.data?.original.map { "\($0) Hz" } ?? "No answer")
                        row("Test, read back", "\(record.data?.test.map { "\($0) Hz" } ?? "–"), \(record.data?.readBack.map { "\($0) Hz" } ?? "–")")
                        row("Put back", record.data?.restored == true ? "Yes" : "No", color: record.data?.restored == true ? .razerGreen : .batteryMid)
                    }
                }
                outcomeRow("Polling rate", record.outcome)
            }
        }
    }

    private var lighting: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("Lighting", changes: true)
            if model.running {
                running("Watch your mouse: dark, then red…")
            } else if let record = model.report?.lighting, record.data != nil {
                if let data = record.data, data.dimShown {
                    question("Did the lights go dark for a moment?", $model.dimmed)
                    if data.redShown { question("Then did they turn red?", $model.turnedRed) }
                    note(data.restored ? "Everything has been put back." : "Something couldn't be put back. Check the lighting in the popover.")
                } else {
                    outcomeRow("Lighting", record.outcome)
                }
            } else {
                note("Watch your mouse while this runs. Its lights go dark for three seconds, then turn red for three seconds. Afterwards they go back to your brightness and to MacRazer's current lighting setting.")
            }
        }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("Side buttons", changes: false)
            note("Press every extra button once. Only this mouse is listened to.")
            if model.listening {
                card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.buttonsSeen.isEmpty ? "Nothing yet" : "Seen so far")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(model.buttonsSeen, id: \.self) { label in
                                Text(ButtonCapture.friendlyName(label))
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.razerGreen.opacity(0.25)))
                            }
                        }
                    }
                }
                note("Side keys that type numbers are normal on some models. That's useful to know too.")
            } else {
                warning("MacRazer can't hear this mouse's buttons right now. You can skip this step.")
            }
        }
    }

    private var review: some View {
        let report = model.finalReport()
        return VStack(alignment: .leading, spacing: 10) {
            title("Review")
            note("Copy the report, or open a GitHub issue and paste it in. Nothing leaves your Mac until you do.")
            if let report, let verdict = report.verdict {
                card {
                    VStack(spacing: 4) {
                        row(report.device.name, String(format: "0x%04X", report.device.productID) + (report.identify.data?.firmware.map { ", \($0)" } ?? ""))
                        if !verdict.passed.isEmpty { row("Worked", verdict.passed.joined(separator: ", "), color: .razerGreen) }
                        if !verdict.failed.isEmpty { row("Didn't work", verdict.failed.joined(separator: ", "), color: .batteryMid) }
                        if !verdict.notSupported.isEmpty { row("Not on this mouse", verdict.notSupported.joined(separator: ", ")) }
                        if !verdict.skipped.isEmpty { row("Skipped", verdict.skipped.joined(separator: ", ")) }
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
                .textFieldStyle(.roundedBorder).controlSize(.small)
            // No reply-email field yet: Copy and the GitHub issue are both public-facing and
            // leave it out by design, so it would be asked for and go nowhere. It arrives with
            // Send, which delivers to the maintainer alone.
            VStack(alignment: .trailing, spacing: 2) {
                TextEditor(text: Binding(get: { model.comment },
                                         set: { model.comment = String($0.prefix(DeviceReportOutput.maxComment)) }))
                    .font(.system(size: 12))
                    .frame(height: 54)
                    .overlay(alignment: .topLeading) {
                        if model.comment.isEmpty {
                            Text("Comments or feedback (optional)").font(.system(size: 12)).foregroundStyle(.tertiary)
                                .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                // Verbatim: a localized number would print 2000 as "2.000" in some regions.
                Text(verbatim: "\(model.comment.count) / \(DeviceReportOutput.maxComment)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if model.copied { note("Copied.") }
            if model.issueOpened { note("The full report is on your clipboard. Paste it into the issue before you submit it.") }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack {
            switch model.stage {
            case .intro:
                Button("Cancel", action: onClose)
                Spacer()
                Button("Start") { model.start() }.keyboardShortcut(.defaultAction)
            case .permission:
                Button("Continue without it") { model.continueWithoutAccess() }
                Spacer()
                if model.needsRelaunch {
                    Button("Quit and reopen") { model.relaunchAndResume() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Grant access") { model.grantAccess() }.keyboardShortcut(.defaultAction)
                }
            case .review:
                Button("Copy") { model.copyReport() }
                Button("Open GitHub issue") { model.openGitHubIssue() }
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            default:
                Button("Back") { model.back() }.disabled(model.running || model.stage == .identify)
                Spacer()
                if let index = DeviceTestModel.steps.firstIndex(of: model.stage) {
                    Text("Step \(index + 1) of \(DeviceTestModel.steps.count - 1)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                stepButtons
            }
        }
        .controlSize(.regular)
    }

    /// Run and Skip for steps that change something and haven't run yet; Next otherwise.
    @ViewBuilder private var stepButtons: some View {
        switch model.stage {
        case .dpi where model.report?.dpi.data == nil && model.report?.dpi.error == nil:
            Button("Skip") { model.next() }.disabled(model.running)
            Button("Run") { Task { await model.runDPI() } }.disabled(model.running).keyboardShortcut(.defaultAction)
        case .polling where model.report?.polling.data == nil && model.report?.polling.error == nil:
            Button("Skip") { model.next() }.disabled(model.running)
            Button("Run") { Task { await model.runPolling() } }.disabled(model.running).keyboardShortcut(.defaultAction)
        case .lighting where model.report?.lighting.data == nil:
            Button("Skip") { model.next() }.disabled(model.running)
            Button("Run") { Task { await model.runLighting() } }.disabled(model.running).keyboardShortcut(.defaultAction)
        case .buttons:
            Button(model.buttonsSeen.isEmpty ? "Skip" : "Next") { model.next() }.keyboardShortcut(.defaultAction)
        default:
            Button("Next") { model.next() }
                .disabled(model.running || model.report == nil || (model.stage == .lighting && !model.lightingAnswered))
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Pieces

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
    }

    private func stepTitle(_ text: String, changes: Bool) -> some View {
        HStack(spacing: 8) {
            title(text)
            tag(changes ? "Changes, then puts back" : "Reads only", color: changes ? .batteryMid : .razerGreen)
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
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

    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(color).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
    }

    private func outcomeRow(_ label: String, _ outcome: DeviceReport.Outcome) -> some View {
        let (text, color): (String, Color) = {
            switch outcome {
            case .passed: return ("Works", .razerGreen)
            case .failed: return ("Didn't work", .batteryMid)
            case .notSupported: return ("Not on this mouse", .secondary)
            case .skipped: return ("Skipped", .secondary)
            }
        }()
        return row(label, text, color: color)
    }

    private func question(_ text: String, _ answer: Binding<DeviceTestModel.Answer?>) -> some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 12, weight: .medium))
                Picker("", selection: answer) {
                    Text("Yes").tag(DeviceTestModel.Answer?.some(.yes))
                    Text("No").tag(DeviceTestModel.Answer?.some(.no))
                    Text("Not sure").tag(DeviceTestModel.Answer?.some(.unsure))
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
        }
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// App-level settings, in a real window rather than another card in the popover.
///
/// The popover is for the *mouse* — DPI, polling, lighting, battery. These are settings for
/// MacRazer itself, they're set once and rarely revisited, and they need room to explain
/// themselves (what "install automatically" actually does, why the login item is unavailable
/// from a mounted disk image). Stacking that on the bottom of a popover that already scrolls
/// past five cards was the wrong shape for both.
struct SettingsView: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var launchAtLogin: LaunchAtLogin
    @ObservedObject var updateChecker: UpdateChecker
    /// Not optional, for the same reason as `AboutView.onDone`: a defaulted no-op ships a
    /// Done button that does nothing and compiles fine.
    var onDone: () -> Void
    /// Called when "install automatically" is switched, so the owner can act on an update that
    /// is *already* known — the one moment the user is watching for the setting to do
    /// something, and the moment none of the other triggers fire.
    var onAutoInstallChanged: (() -> Void)?
    /// The crash window's "Don't Ask Again" writes the same key, so this is how to undo it.
    @AppStorage(CrashLogScanner.offerKey) private var offerCrashReports = true
    @ObservedObject var appearance: AppearanceSettings = .shared
    @ObservedObject var usageStats: UsageStats = .shared
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            titledSection("General") {
                launchAtLoginRow
                connectionSoundsRow
                // Hidden rather than disabled for a mouse with no battery: there is no
                // percentage to show, so the switch would be a promise about nothing.
                if controller.deviceHasBattery { batteryPercentRow }
                // Hidden while there's nowhere to send a report; see `CrashReporting`.
                if CrashReporting.isAvailable { crashReportsRow }
            }
            // Only in a build that can send stats: see `WorkerEndpoint`.
            if usageStats.isAvailable {
                titledSection("Privacy") {
                    mouseModelsRow
                    usageStatsRow
                    deleteDataRow
                }
            }
            titledSection("Appearance") {
                themeRow
                glassRow
            }
            titledSection("Updates") {
                autoInstallRow
                versionRow
            }
            footer
        }
        .padding(22)
        .frame(width: 440)
        // The login switch mirrors the system's registration, which the user can change in
        // System Settings while this window sits open in the background.
        .onAppear { launchAtLogin.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(Color.razerGreenBright.opacity(0.20))
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.razerGreenBright)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacRazer Settings").font(.system(size: 17, weight: .semibold))
                Text("How the app itself behaves. Mouse controls stay in the menu bar popover.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Rows

    private var launchAtLoginRow: some View {
        settingRow(
            title: "Start MacRazer at login",
            detail: "The menu bar item is there after a restart, without opening the app yourself.",
            isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) }),
            enabled: launchAtLogin.isSupported
        ) {
            // Shown rather than hidden when unavailable: running straight from the disk image
            // is a real thing people do, and "why is this switch dead" deserves an answer.
            if !launchAtLogin.isSupported {
                sectionNote("Move MacRazer to your Applications folder to use this. A login item "
                     + "pointing into a disk image stops working the moment it's ejected.")
            } else if let error = launchAtLogin.lastError {
                sectionNote(error, color: .batteryLow)
            } else if launchAtLogin.needsApproval {
                Button("Approve MacRazer in Login Items…") { launchAtLogin.openLoginItemsSettings() }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(Color.razerGreenText)
            }
        }
    }

    private var connectionSoundsRow: some View {
        settingRow(
            title: "Connection sounds",
            detail: "Play a sound when the mouse connects or disconnects.",
            isOn: Binding(get: { controller.connectionSoundsEnabled },
                          set: { controller.connectionSoundsEnabled = $0 })
        )
    }

    private var batteryPercentRow: some View {
        settingRow(
            title: "Show battery % in menu bar",
            detail: "Off leaves just the mouse icon, which takes less room in a crowded menu bar.",
            isOn: Binding(get: { controller.showPercentInMenuBar },
                          set: { controller.showPercentInMenuBar = $0 })
        )
    }

    private var themeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Theme").font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 12)
                Picker("Theme", selection: $appearance.theme) {
                    ForEach(PopoverTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            sectionNote("System follows macOS. Razer Green is always dark.")
        }
    }

    private var glassRow: some View {
        settingRow(
            title: "Glass effect",
            detail: "The popover and windows let the desktop show through. Turn it off for a solid "
                + "background, which is easier to read over busy windows.",
            isOn: $appearance.glass
        )
    }

    private var crashReportsRow: some View {
        settingRow(
            title: "Offer to send crash reports",
            detail: "If MacRazer quits unexpectedly, ask next time whether to send a report. "
                + "You see exactly what's in it first.",
            isOn: $offerCrashReports
        )
    }

    private var mouseModelsRow: some View {
        settingRow(
            title: "Count my mouse model",
            detail: "The update check also says which mouse model is connected, so I can see which "
                + "mice people use. It's counted with nothing that identifies this Mac.",
            isOn: $updateChecker.sendsMouseModels
        )
    }

    private var usageStatsRow: some View {
        settingRow(
            title: "Share anonymous usage stats",
            detail: "Your mouse model, app version and macOS version, sent when you install, update or "
                + "plug in a new mouse. It helps me decide which mice to support next.",
            isOn: Binding(get: { usageStats.consent == .granted }, set: { usageStats.setConsent($0) })
        ) {
            DisclosureGroup("What's sent") {
                UsageStatsJSON(ping: usageStats.preview)
                    .padding(.top, 4)
            }
            .font(.system(size: 11.5, weight: .medium))
            if let status = usageStatsStatus {
                sectionNote(status)
            }
        }
    }

    private var usageStatsStatus: String? {
        guard usageStats.consent == .granted else { return nil }
        guard let sent = usageStats.lastSentAt else { return "Nothing sent yet. It goes with the next launch or mouse." }
        // The formatter says "in 0 seconds" for a moment ago.
        let when = Date().timeIntervalSince(sent) < 60
            ? "just now" : Self.relativeDate.localizedString(for: sent, relativeTo: Date())
        return "Last sent \(when)" + (usageStats.lastSentVersion.map { ", for version \($0)." } ?? ".")
    }

    /// Always offered, even with nothing sent from this install: a reinstall keeps the same ID,
    /// so the server may still have this Mac from before.
    private var deleteDataRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Delete what's stored").font(.system(size: 12.5, weight: .medium))
                sectionNote(deletionNote)
            }
            Spacer(minLength: 0)
            Button("Delete My Data…") { confirmingDelete = true }
                .controlSize(.small)
                .disabled(usageStats.deletion == .deleting)
        }
        .confirmationDialog("Delete this Mac's usage stats?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await usageStats.deleteMyData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac's ID is removed from the server and sharing turns off. "
                + "The anonymous counts stay, with nothing that links them to you.")
        }
    }

    private var deletionNote: String {
        switch usageStats.deletion {
        case .deleting: return "Deleting…"
        case .deleted: return "Done. This Mac's ID is gone from the server."
        case .willRetry: return "Couldn't reach the server. MacRazer will keep trying, at each launch and when a mouse connects."
        case .idle: return "Removes this Mac's ID from the server and turns sharing off. "
            + "The anonymous counts stay, with nothing that links them to you."
        }
    }

    private var autoInstallRow: some View {
        settingRow(
            title: "Install updates automatically",
            detail: "Download, replace and relaunch on its own when a new version appears. "
                + "Never while the popover is open.",
            isOn: Binding(
                get: { updateChecker.autoInstallEnabled },
                set: { updateChecker.autoInstallEnabled = $0; onAutoInstallChanged?() }
            ),
            enabled: updateChecker.canInstallInPlace
        ) {
            if !updateChecker.canInstallInPlace {
                sectionNote("Not available here, because MacRazer can't replace itself from this location. "
                     + "Move it to your Applications folder.")
            } else if !updateChecker.autoInstallEnabled {
                sectionNote("Off: you'll get a dot on the menu bar icon and a card in the popover instead.")
            }
        }
    }

    /// The one non-toggle row: what you're running, when it was last checked, and a way to ask
    /// again — the questions someone opens an Updates section to answer.
    private var versionRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Version \(updateChecker.currentVersion)")
                    .font(.system(size: 12.5, weight: .medium))
                Text(checkStatusText)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            // An update is available: this section is where the app puts everything about
            // updating, so it should be able to do it rather than send the user to the popover.
            if updateChecker.latestVersion != nil, !updateChecker.isBusy {
                Button("Install Now") {
                    Task { await updateChecker.downloadAndInstall() }
                }
                .controlSize(.small)
                .buttonStyle(RazerProminentButtonStyle())
            }
            Button {
                Task { await updateChecker.checkForUpdatesNow(userRequested: true) }
            } label: {
                if updateChecker.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Check Now")
                }
            }
            .controlSize(.small)
            // `checkForUpdatesNow` returns immediately while an install runs; without `isBusy`
            // here the button would depress and do nothing, which reads as broken.
            .disabled(updateChecker.isChecking || updateChecker.isBusy)
        }
    }

    /// Built once for the process: formatter construction resolves a locale and a calendar,
    /// and this is read from a view body that re-renders on every publish from three observed
    /// objects — including the controller's battery sample every ~15s.
    private static let relativeDate = RelativeDateTimeFormatter()

    private var checkStatusText: String {
        if updateChecker.isChecking { return "Checking…" }
        switch updateChecker.phase {
        case .downloading(let f): return "Downloading the update… \(Int(f * 100))%"
        case .installing: return "Installing the update…"
        case .restarting: return "Restarting into the new version…"
        case .needsRestart: return "Update installed. Quit and reopen MacRazer to use it."
        case .idle: break
        }
        if let latest = updateChecker.latestVersion {
            // Don't tell someone to go and do a thing the app is about to do for them.
            return updateChecker.autoInstallEnabled
                ? "Version \(latest) is available and will install itself shortly."
                : "Version \(latest) is available."
        }
        guard let last = updateChecker.lastCheckedAt else {
            return "Not checked yet. MacRazer checks every few hours."
        }
        return "Up to date. Last checked \(Self.relativeDate.localizedString(for: last, relativeTo: Date()))."
    }

    // MARK: Building blocks

    /// A labelled switch with its explanation underneath, plus an optional slot for a caption
    /// that only appears in some states (unavailable, needs approval, failed).
    private func settingRow<Extra: View>(
        title: String, detail: String, isOn: Binding<Bool>, enabled: Bool = true,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) {
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .toggleStyle(.switch)
            .tint(.razerGreen)
            .controlSize(.small)
            .disabled(!enabled)
            sectionNote(detail)
            extra()
        }
        .opacity(enabled ? 1 : 0.55)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { onDone() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(RazerProminentButtonStyle())
        }
    }
}

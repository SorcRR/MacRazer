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
    var onDone: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            section("General") {
                launchAtLoginRow
                // Hidden rather than disabled for a mouse with no battery: there is no
                // percentage to show, so the switch would be a promise about nothing.
                if controller.deviceHasBattery { batteryPercentRow }
            }
            section("Updates") {
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
                note("Move MacRazer to your Applications folder to use this — a login item "
                     + "pointing into a disk image stops working the moment it's ejected.")
            } else if let error = launchAtLogin.lastError {
                note(error, color: .batteryLow)
            } else if launchAtLogin.needsApproval {
                Button("Approve MacRazer in Login Items…") { launchAtLogin.openLoginItemsSettings() }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(Color.razerGreen)
            }
        }
    }

    private var batteryPercentRow: some View {
        settingRow(
            title: "Show battery % in menu bar",
            detail: "Off leaves just the mouse icon, which takes less room in a crowded menu bar.",
            isOn: Binding(get: { controller.showPercentInMenuBar },
                          set: { controller.showPercentInMenuBar = $0 })
        )
    }

    private var autoInstallRow: some View {
        settingRow(
            title: "Install updates automatically",
            detail: "Download, replace and relaunch on its own when a new version appears. "
                + "Never while the popover is open.",
            isOn: $updateChecker.autoInstallEnabled,
            enabled: updateChecker.canInstallInPlace
        ) {
            if !updateChecker.canInstallInPlace {
                note("Unavailable here — MacRazer can't replace itself from this location. "
                     + "Move it to your Applications folder.")
            } else if !updateChecker.autoInstallEnabled {
                note("Off: you'll get a dot on the menu bar icon and a card in the popover instead.")
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
            .disabled(updateChecker.isChecking)
        }
    }

    private var checkStatusText: String {
        if updateChecker.isChecking { return "Checking…" }
        if let latest = updateChecker.latestVersion {
            return "Version \(latest) is available — open the popover to install it."
        }
        guard let last = updateChecker.lastCheckedAt else {
            return "Not checked yet. MacRazer checks once a day."
        }
        let when = RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
        return "Up to date — last checked \(when)."
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
            note(detail)
            extra()
        }
        .opacity(enabled ? 1 : 0.55)
    }

    private func note(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.6)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { onDone?() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

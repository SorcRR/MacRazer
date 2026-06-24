// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// First-run setup / permissions screen. Explains the two macOS permissions MacRazer needs,
/// shows their live status, and grants them with the native prompts. Reachable any time from
/// the menu bar's "Setup & Permissions…".
struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel
    @ObservedObject var controller: MouseController
    var onDone: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            permissionRow(
                title: "Input Monitoring",
                why: "Lets MacRazer talk to your mouse — battery, DPI, polling rate and lighting all need this.",
                granted: model.inputMonitoring,
                required: true,
                grant: { model.grantInputMonitoring() },
                openSettings: { model.openInputMonitoringSettings() }
            )
            permissionRow(
                title: "Accessibility",
                why: "Only for remapping the extra mouse buttons. Skip it if you don't remap buttons.",
                granted: model.accessibility,
                required: false,
                grant: { model.grantAccessibility() },
                openSettings: { model.openAccessibilitySettings() }
            )
            if model.needsRelaunch { relaunchBanner }
            statusLine
            if !model.inputMonitoring { relaunchTip }
            footer
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { model.recheck() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(Color.razerGreenBright.opacity(0.20))
                Image(nsImage: MenuBarIcon.mouse(pointSize: 24, razerCutout: true))
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(Color.razerGreenBright)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up MacRazer").font(.system(size: 17, weight: .semibold))
                Text("A couple of macOS permissions and you're ready to go.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Permission row

    private func permissionRow(
        title: String, why: String, granted: Bool, required: Bool,
        grant: @escaping () -> Void, openSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !required {
                    Text("Optional")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.10), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusPill(granted: granted)
            }
            Text(why)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !granted {
                HStack(spacing: 10) {
                    Button(action: grant) {
                        Text("Grant…").font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.razerGreen)
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.bordered)
                        .font(.system(size: 12))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(granted ? Color.batteryFull.opacity(0.45) : Color.clear, lineWidth: 1)
        )
    }

    private func statusPill(granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 11, weight: .semibold))
            Text(granted ? "Granted" : "Needed").font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(granted ? Color.batteryFull : Color.batteryMid)
    }

    // MARK: Relaunch

    private var relaunchBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.batteryMid)
            VStack(alignment: .leading, spacing: 2) {
                Text("Relaunch to finish").font(.system(size: 12, weight: .semibold))
                Text("Input Monitoring is on, but MacRazer must relaunch for it to take effect.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Relaunch") { model.relaunch() }
                .buttonStyle(.borderedProminent).tint(.razerGreen)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.batteryMid.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Device-detected confirmation

    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(controller.connected ? Color.batteryFull : Color.secondary)
                .frame(width: 8, height: 8)
            if controller.connected, let name = controller.deviceName {
                Text(verbatim: "\(name) connected").font(.system(size: 11, weight: .medium))
            } else if model.inputMonitoring {
                Text("No Razer mouse detected yet — connect the 2.4 GHz dongle or a USB-C cable (Bluetooth isn't supported).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Grant Input Monitoring to detect your mouse.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    /// Explains the macOS gotcha: enabling the permission in System Settings while the app is
    /// already running has no effect until relaunch (the process caches its TCC decision).
    private var relaunchTip: some View {
        Text("Already enabled it in System Settings but it still shows “Needed”? macOS only applies "
             + "Input Monitoring to a freshly-launched app — use Quit & Relaunch below.")
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Re-check") { model.recheck() }
                .buttonStyle(.bordered).font(.system(size: 12))
            if !model.inputMonitoring {
                Button("Quit & Relaunch") { model.relaunch() }
                    .buttonStyle(.bordered).font(.system(size: 12))
                    .help("Relaunch so macOS applies an Input Monitoring grant made while the app was running.")
            }
            Spacer()
            Button(model.allRequiredGranted ? "Done" : "Close") { onDone?() }
                .buttonStyle(.borderedProminent)
                .tint(model.allRequiredGranted ? .razerGreen : .gray)
                .font(.system(size: 12, weight: .medium))
        }
    }
}

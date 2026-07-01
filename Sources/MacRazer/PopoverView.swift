// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import AppKit

/// Reports the main page's measured height so the popover can size to it.
private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private enum Effect: String, CaseIterable, Identifiable {
    case staticColor = "Static"
    case spectrum = "Spectrum"
    case wave = "Wave"
    case off = "Off"
    var id: Self { self }
}

extension Color {
    /// Razer brand green (#44D62C) — the single accent. Budget: logo, slider, active chip/segment.
    static let razerGreen = Color(red: 0x44 / 255, green: 0xD6 / 255, blue: 0x2C / 255)
    /// A brighter, more vivid green for the logo so it really pops on the dark background.
    static let razerGreenBright = Color(red: 0.42, green: 1.0, blue: 0.25)
    // Battery *state* uses Apple system colors (meaning), never the brand green.
    static let batteryFull = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    static let batteryMid = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
    static let batteryLow = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3B / 255)
}

struct PopoverView: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    @ObservedObject var updateChecker: UpdateChecker

    enum Page { case main, color, buttons, usage, profiles }
    @State private var page: Page = .main
    @State private var isAddingProfile = false
    @State private var newProfileName = ""
    /// Suppresses the `effect` picker's `onChange`-driven HID write for exactly one
    /// programmatic `effect` change during a profile apply — `applyProfile` already sent the
    /// right lighting command, and re-sending it here would also re-clear the just-set active
    /// profile. Set only when the value will actually change; consumed (and cleared) by the
    /// `onChange` handler itself.
    @State private var isApplyingProfileLocally = false

    @State private var dpiValue: Double = 1600
    @State private var brightnessValue: Double = 100
    @State private var color: Color = .razerGreen
    @State private var effect: Effect = .staticColor
    /// Recallable custom DPI — persisted per-mouse, and never above the mouse's max.
    @State private var customDPI: Int = 8000

    private let pollRates = RazerCommands.supportedPollingRates
    private let defaultStages = [400, 800, 1600, 3200, 6400]
    /// The connected mouse's actual configured DPI stages, or sensible defaults.
    private var displayedStages: [Int] {
        controller.dpiStages.isEmpty ? defaultStages : controller.dpiStages
    }
    // Distinct hues with a true red (SwiftUI .red is a warm orange-red; .green duplicated razerGreen).
    private let swatches: [Color] = [
        Color(red: 1.0, green: 0.0, blue: 0.0),    // true red
        Color(red: 1.0, green: 0.5, blue: 0.0),    // orange
        Color(red: 1.0, green: 0.85, blue: 0.0),   // yellow
        .razerGreen,                                // green
        Color(red: 0.0, green: 0.8, blue: 1.0),    // cyan
        Color(red: 0.15, green: 0.35, blue: 1.0),  // blue
        Color(red: 0.6, green: 0.2, blue: 1.0),    // purple
        Color(red: 1.0, green: 0.2, blue: 0.65),   // pink
    ]

    /// Popover sizes to the MAIN page content (no empty space); sub-pages match that height
    /// so navigating doesn't resize. Buttons page scrolls if taller; colour page is centred.
    private let popoverWidth: CGFloat = 320
    @State private var mainHeight: CGFloat = 0

    var body: some View {
        ZStack {
            switch page {
            case .main: mainPage.transition(.move(edge: .leading))
            case .color: colorPage.transition(.move(edge: .trailing))
            case .buttons: buttonsPage.transition(.move(edge: .trailing))
            case .usage: usagePage.transition(.move(edge: .trailing))
            case .profiles: profilesPage.transition(.move(edge: .trailing))
            }
        }
        .frame(width: popoverWidth)
        .frame(height: page == .main ? nil : (mainHeight > 0 ? mainHeight : nil))
        // While a sub-page is showing, the main page is unmounted and the preference reverts
        // to its 0 default — keep the last real measurement so sub-pages stay locked to the
        // main page's height instead of resizing once the transition finishes.
        .onPreferenceChange(HeightKey.self) { if $0 > 0 { mainHeight = $0 } }
        .animation(.easeInOut(duration: 0.26), value: page)
    }

    // MARK: Sub-pages

    private var colorPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ColorPickerPage(color: $color, onBack: { page = .main }) { rgb in
                controller.setStatic(rgb)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
    }

    private var buttonsPage: some View {
        ScrollView {
            RemapView(remapper: remapper, onBack: { page = .main })
                .frame(maxWidth: .infinity)
        }
    }

    private var usagePage: some View {
        ScrollView {
            UsageGraphView(controller: controller, onBack: { page = .main })
                .frame(maxWidth: .infinity)
        }
    }

    private var profilesPage: some View {
        ScrollView {
            ProfilesView(controller: controller, remapper: remapper, onBack: { page = .main })
                .frame(maxWidth: .infinity)
        }
    }

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerCard
            if let version = updateChecker.latestVersion { updateCard(version) }
            // A Razer mouse on Bluetooth can't be controlled (no control protocol over BT) —
            // explain it instead of just showing "offline".
            if controller.bluetoothMouseName != nil && !controller.connected { bluetoothNotice }
            profilesCard.disabled(!controller.connected).opacity(controller.connected ? 1 : 0.45)
            // Battery stays readable (last-known) but dims when offline; its refresh button
            // stays active so you can retry.
            if controller.deviceHasBattery {
                batteryCard.opacity(controller.connected ? 1 : 0.55)
            }
            // Live mouse-config sections: dim AND disable while disconnected.
            Group {
                dpiCard
                pollCard
                if controller.deviceHasLighting { lightingCard } // hidden for no-LED mice (e.g. Atheris)
            }
            .disabled(!controller.connected)
            .opacity(controller.connected ? 1 : 0.45)

            configureButton // software remap — works offline, stays enabled
            if controller.deviceHasBattery { settingsCard }
            footer
        }
        .padding(12)
        .frame(width: popoverWidth)
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        .onAppear {
            if controller.dpi != 0 { dpiValue = Double(controller.dpi) }
            brightnessValue = Double(controller.brightness)
            loadCustomDPI()
        }
        .onChange(of: controller.dpi) { _, new in if new != 0 { dpiValue = Double(new) } }
        .onChange(of: controller.brightness) { _, new in brightnessValue = Double(new) }
        .onChange(of: controller.deviceKey) { _, _ in loadCustomDPI() } // reload/clamp per mouse
        .onChange(of: controller.deviceMaxDPI) { _, _ in loadCustomDPI() }
    }

    // MARK: Custom DPI (per-mouse, clamped to the model's max)

    /// nil while no device key is known — persisting then would land in a "default" slot
    /// shared by every mouse and never migrated to the real key once it resolves.
    private var customDPIKey: String? {
        controller.deviceKey.map { "customDPI-\($0)" }
    }

    private func loadCustomDPI() {
        let stored = customDPIKey.flatMap { UserDefaults.standard.object(forKey: $0) as? Int }
            ?? min(8000, controller.deviceMaxDPI)
        let clamped = min(max(stored, 100), controller.deviceMaxDPI) // reset if it exceeds this mouse's max
        customDPI = clamped
        if clamped != stored, let key = customDPIKey { UserDefaults.standard.set(clamped, forKey: key) }
    }

    private func saveCustomDPI(_ value: Int) {
        customDPI = value
        if let key = customDPIKey { UserDefaults.standard.set(value, forKey: key) }
    }

    // MARK: Header

    private var headerCard: some View {
        card {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Color.razerGreenBright.opacity(0.20))
                    Image(nsImage: MenuBarIcon.mouseModel(pid: controller.deviceID, razerCutout: controller.deviceHasLighting, pointSize: 20))
                        .renderingMode(.template)
                        .resizable().scaledToFit()
                        .frame(width: 19, height: 19)
                        .foregroundStyle(Color.razerGreenBright)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.deviceName ?? "No mouse connected")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(headerSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let ct = connectionType { connectionChip(ct) }
                    }
                }
                Spacer()
                Circle()
                    .fill(controller.connected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var headerSubtitle: String {
        if controller.connected { return controller.deviceSupported ? "Connected" : "Connected · limited support" }
        if controller.bluetoothMouseName != nil { return "On Bluetooth" }
        if controller.deviceName != nil { return "Offline" }
        return "Connect a Razer mouse"
    }

    /// The active control transport, shown as a small chip beside "Connected". `charging` implies
    /// a USB-C cable is attached (wired); otherwise control is going over the 2.4 GHz dongle.
    /// (Bluetooth can't carry control, so it never reads "Connected" — it's surfaced separately.)
    private var connectionType: (symbol: String, label: String)? {
        guard controller.connected else { return nil }
        return controller.charging
            ? ("cable.connector", "Wired")
            : ("antenna.radiowaves.left.and.right", "2.4 GHz")
    }

    private func connectionChip(_ ct: (symbol: String, label: String)) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ct.symbol).font(.system(size: 8.5, weight: .bold))
            Text(ct.label).font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(Color.razerGreen)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(Color.razerGreen.opacity(0.15), in: Capsule())
    }

    /// Shown when a Razer mouse is detected on Bluetooth: control needs USB / the 2.4 GHz dongle.
    private var bluetoothNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.batteryMid)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Connected via Bluetooth").font(.system(size: 12, weight: .semibold))
                Text("\(controller.bluetoothMouseName ?? "Your Razer mouse") only reports battery, DPI and lighting over the 2.4 GHz dongle or USB-C — not Bluetooth. Switch its mode to use MacRazer.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.batteryMid.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
    }

    // MARK: Profiles

    /// Quick-switch row: a chip per saved profile (filled green when active) plus a "+" chip to
    /// save the current setup. Kept on the main page so switching never needs a page navigation —
    /// only the rarely-needed rename/delete flow lives behind "Manage…".
    private var profilesCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionLabel("Profiles", "person.crop.square.on.square.angled")
                    Spacer()
                    if !controller.profiles.isEmpty {
                        Button("Manage…") { page = .profiles }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.razerGreen)
                    }
                }
                if controller.profiles.isEmpty && !isAddingProfile {
                    HStack(spacing: 8) {
                        Text("Save your current setup as a profile")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        addProfileChip
                    }
                } else {
                    HStack(spacing: 6) {
                        ForEach(controller.profiles) { profileChip($0) }
                        if !isAddingProfile { addProfileChip }
                    }
                }
                if isAddingProfile { addProfileField }
            }
        }
    }

    private func profileChip(_ profile: MouseProfile) -> some View {
        let active = profile.id == controller.activeProfileID
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                controller.applyProfile(profile, remapper: remapper)
                if let parsed = Effect(rawValue: profile.effect), parsed != effect {
                    // Set the flag only when the consuming onChange is guaranteed to fire
                    // and clear it: the value must actually change AND the effect picker
                    // (which hosts the onChange) must be mounted — it only exists for
                    // lighting-capable mice. A time-based reset could race SwiftUI's
                    // delivery; a flag set with the picker unmounted would strand.
                    isApplyingProfileLocally = controller.deviceHasLighting
                    effect = parsed
                }
                color = Color(red: Double(profile.color.r) / 255, green: Double(profile.color.g) / 255, blue: Double(profile.color.b) / 255)
            }
        } label: {
            Text(profile.name)
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: active ? .semibold : .regular))
        .foregroundStyle(active ? .white : .secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(active ? Color.razerGreen : Color.primary.opacity(0.08), in: Capsule())
        .lineLimit(1)
    }

    private var addProfileChip: some View {
        Button {
            newProfileName = "Profile \(controller.profiles.count + 1)"
            isAddingProfile = true
        } label: {
            Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.razerGreen)
        .frame(width: 24, height: 24)
        .background(Color.razerGreen.opacity(0.12), in: Circle())
        .overlay(Circle().stroke(Color.razerGreen.opacity(0.55), lineWidth: 1))
    }

    private var addProfileField: some View {
        HStack(spacing: 6) {
            TextField("Profile name", text: $newProfileName, onCommit: saveNewProfile)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            Button("Save", action: saveNewProfile)
                .buttonStyle(.borderedProminent)
                .tint(.razerGreen)
                .controlSize(.small)
                .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { isAddingProfile = false }
                .buttonStyle(.plain)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }

    private func saveNewProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        controller.saveCurrentAsProfile(name: name, effect: effect.rawValue, color: color.rgb, remapper: remapper)
        isAddingProfile = false
    }

    // MARK: Update notice

    private func updateCard(_ version: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.razerGreen)
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available").font(.system(size: 12, weight: .semibold))
                    Text("Version \(version) is out — you're on \(appVersion).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    updateChecker.dismiss(version)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
            if let error = updateChecker.downloadError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            }
            Button {
                Task { await updateChecker.downloadAndOpenDMG() }
            } label: {
                HStack(spacing: 6) {
                    if updateChecker.isDownloading {
                        ProgressView().controlSize(.small)
                        Text("Downloading…")
                    } else {
                        Image(systemName: "arrow.down.to.line")
                        Text("Download")
                    }
                }
                .font(.system(size: 11.5, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .tint(.razerGreen)
            .controlSize(.small)
            .disabled(updateChecker.isDownloading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.razerGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
    }

    // MARK: Battery hero

    private var batteryLevel: Double { Double(controller.batteryPercent ?? 0) / 100 }
    private var batteryColor: Color {
        // No reading yet (nil) is "unknown," not "critically low" — don't flash red before the
        // first successful poll completes.
        guard let pct = controller.batteryPercent else { return .secondary }
        return batteryLevelColor(forPercent: pct)
    }

    private var batteryCard: some View {
        card {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                batteryGauge
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: controller.batteryPercent.map { "\($0)" } ?? "—")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(controller.batteryPercent ?? 100 < 15 ? Color.batteryLow : .primary)
                        .contentTransition(.numericText())
                    Text("%").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                usageButton
                refreshButton
            }
            // State-coloured level bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(batteryColor)
                        .frame(width: max(6, geo.size.width * batteryLevel))
                        .animation(.easeInOut, value: batteryLevel)
                }
            }
            .frame(height: 6)
            Text(batterySubtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            if needsPermission {
                Button {
                    AppDelegate.openInputMonitoringSettings()
                } label: {
                    Label("Grant Input Monitoring…", systemImage: "lock.shield")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.razerGreen)
            }
        }
        }
    }

    private var needsPermission: Bool {
        guard !controller.connected, let err = controller.lastError else { return false }
        return HIDDevice.errorLooksPermissionDenied(err)
    }

    /// Custom battery glyph whose fill is proportional to the exact charge level and
    /// coloured by state — so it visibly tracks the percentage (the SF Symbol only had 5 steps).
    private var batteryGauge: some View {
        let bodyW: CGFloat = 30, bodyH: CGFloat = 15, inset: CGFloat = 2.5
        let level = controller.batteryPercent == nil ? 0 : batteryLevel
        return HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5)
                RoundedRectangle(cornerRadius: 2)
                    .fill(batteryColor)
                    .frame(width: max(2, (bodyW - inset * 2) * level), height: bodyH - inset * 2)
                    .padding(.leading, inset)
                    .animation(.easeInOut, value: level)
            }
            .frame(width: bodyW, height: bodyH)
            .overlay {
                if controller.charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 0.5)
                }
            }
            // Battery terminal nub.
            Capsule()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 2.5, height: 5.5)
        }
    }

    private var batterySubtitle: String {
        if controller.charging { return "Charging" }
        if let est = controller.timeEstimate { return est }
        if !controller.connected {
            if controller.bluetoothMouseName != nil { return "On Bluetooth — use 2.4 GHz or USB-C" }
            if needsPermission { return "Needs Input Monitoring permission" }
            return "Disconnected — wake the mouse and refresh"
        }
        if controller.batteryPercent != nil { return "Estimating time remaining…" }
        return "Reading battery…"
    }

    private var usageButton: some View {
        Button { page = .usage } label: {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("View battery usage history")
    }

    private var refreshButton: some View {
        Button {
            controller.refreshAll()
        } label: {
            ZStack {
                if controller.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Refresh battery, DPI and polling rate")
        .disabled(controller.isRefreshing)
    }

    private var dpiCard: some View {
        card {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("DPI", "scope")
                Spacer()
                Text(verbatim: "\(Int(dpiValue))")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            Slider(value: $dpiValue, in: 100...Double(controller.deviceMaxDPI), step: 50) { editing in
                if !editing {
                    let v = Int(dpiValue)
                    controller.setDPI(v)
                    if !displayedStages.contains(v) { saveCustomDPI(v) } // remember the manual value
                }
            }
            .tint(.razerGreen)
            .controlSize(.small)
            HStack(spacing: 6) {
                ForEach(displayedStages, id: \.self) { dpiChip($0) }
                customChip
            }
        }
        }
    }

    /// A fixed-preset DPI chip.
    private func dpiChip(_ value: Int) -> some View {
        let active = Int(dpiValue) == value
        return Button {
            dpiValue = Double(value)
            controller.setDPI(value)
        } label: {
            Text(verbatim: "\(value)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: active ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(active ? .white : .secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(active ? Color.razerGreen : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    /// The custom DPI chip — shows the saved manual value, green outline to mark it as the
    /// custom slot, filled green when the current DPI is a custom (non-preset) value.
    private var customChip: some View {
        let active = !displayedStages.contains(Int(dpiValue))
        return Button {
            dpiValue = Double(customDPI)
            controller.setDPI(customDPI)
        } label: {
            Text(verbatim: "\(active ? Int(dpiValue) : customDPI)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: active ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(active ? .white : Color.razerGreen)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(active ? Color.razerGreen : Color.razerGreen.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(active ? Color.clear : Color.razerGreen.opacity(0.55), lineWidth: 1))
    }

    private var pollCard: some View {
        card {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Polling rate", "timer")
                Spacer()
                Text(verbatim: "\(controller.pollRate == 0 ? 1000 : controller.pollRate) Hz")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Picker("", selection: Binding(
                get: { controller.pollRate == 0 ? 1000 : controller.pollRate },
                set: { controller.setPollRate($0) }
            )) {
                ForEach(pollRates, id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        }
    }

    private var lightingCard: some View {
        card {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Lighting", "light.max")
                Spacer()
                Text(verbatim: "\(Int(brightnessValue))%")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // Brightness.
            HStack(spacing: 6) {
                Image(systemName: "sun.min.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $brightnessValue, in: 0...100, step: 1) { editing in
                    if !editing { controller.setBrightness(Int(brightnessValue)) }
                }
                .tint(.razerGreen)
                .controlSize(.small)
                Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Picker("", selection: $effect) {
                ForEach(Effect.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .onChange(of: effect) { _, new in
                if isApplyingProfileLocally { isApplyingProfileLocally = false; return }
                apply(effect: new)
            }

            if effect == .staticColor {
                HStack(spacing: 7) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, sw in
                        swatch(sw)
                    }
                    customColorWell
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        }
    }

    private func swatch(_ sw: Color) -> some View {
        Circle()
            .fill(sw)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .overlay(Circle().inset(by: -2.5).stroke(Color.primary, lineWidth: isSelected(sw) ? 1.5 : 0))
            .onTapGesture {
                color = sw
                controller.setStatic(sw.rgb)
            }
    }

    /// Circular "custom colour" well — a rainbow ring that opens the system colour panel.
    /// Uses a real button + NSColorPanel bridge (the hidden-ColorPicker trick didn't register
    /// clicks).
    private var customColorWell: some View {
        Button {
            page = .color
        } label: {
            ZStack {
                Circle().fill(AngularGradient(
                    gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
                    center: .center))
                Image(systemName: "eyedropper").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
            }
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ sw: Color) -> Bool {
        let a = sw.rgb, b = color.rgb
        return a.r == b.r && a.g == b.g && a.b == b.b
    }

    private func apply(effect: Effect) {
        switch effect {
        case .staticColor: controller.setStatic(color.rgb)
        case .spectrum: controller.setSpectrum()
        case .wave: controller.setWave()
        case .off: controller.setLightingOff()
        }
    }

    // MARK: Configure buttons

    private var configureButton: some View {
        Button { page = .buttons } label: {
            HStack(spacing: 8) {
                Image(systemName: "keyboard").foregroundStyle(Color.razerGreen)
                Text("Configure Buttons…").font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.connected)
        .opacity(controller.connected ? 1 : 0.45)
    }

    // MARK: Settings

    private var settingsCard: some View {
        card {
            Toggle(isOn: Binding(
                get: { controller.showPercentInMenuBar },
                set: { controller.showPercentInMenuBar = $0 }
            )) {
                Text("Show battery % in menu bar")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .tint(.razerGreen)
            .controlSize(.small)
        }
    }

    // MARK: Footer

    /// Real bundle version (e.g. "0.1.1"); falls back for non-bundled dev runs (`swift run`).
    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    private var footer: some View {
        HStack {
            Text(verbatim: "v\(appVersion) · unofficial").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

extension Color {
    /// Convert to an 8-bit RGB triple for the device.
    var rgb: RGB {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .red
        return RGB(
            r: UInt8((ns.redComponent * 255).rounded()),
            g: UInt8((ns.greenComponent * 255).rounded()),
            b: UInt8((ns.blueComponent * 255).rounded())
        )
    }
}

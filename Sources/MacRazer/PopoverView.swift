// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI
import AppKit

/// Reports the main page's measured height so the popover can size to it.
private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A colour with one value for light surfaces and one for dark, picked by whatever the view is
/// drawn in. The popover and windows can be either, depending on Settings › Appearance.
private func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.isDark ? dark : light })
}

extension Color {
    /// Razer brand green (#44D62C) — the single accent, as a fill: slider, active chip/segment,
    /// switches. The same in light and dark. For green text or icons use `razerGreenText`.
    static let razerGreen = Color(nsColor: NSColor(hex: 0x44D62C))
    /// Green for text and icons. The brand green is too light to read on a light background,
    /// so light surfaces get a darker green (#23891A).
    static let razerGreenText = adaptive(light: NSColor(hex: 0x23891A), dark: NSColor(hex: 0x44D62C))
    /// Text and icons drawn on a `razerGreen` fill. Dark in every theme: white on #44D62C is
    /// only about 1.9:1 contrast.
    static let onRazerGreen = Color(nsColor: NSColor(hex: 0x0D2B07))
    /// The logo's green: brighter than the brand green so it pops on dark, and the darker
    /// text green on light, where a bright green washes out.
    static let razerGreenBright = adaptive(light: NSColor(hex: 0x23891A), dark: NSColor(hex: 0x6BFF40))
    /// The Bluetooth chip's colour. System blue is too dark to read on a dark background,
    /// and this lighter blue too pale on a light one.
    static let bluetoothBlue = adaptive(light: NSColor(hex: 0x0A64D6), dark: NSColor(hex: 0x78B8FF))
    // Lighting swatch hues, shared with the DPI stage chips. A true red: SwiftUI `.red` is
    // a warm orange-red.
    static let swatchRed = Color(red: 1.0, green: 0.0, blue: 0.0)
    static let swatchYellow = Color(red: 1.0, green: 0.85, blue: 0.0)
    static let swatchCyan = Color(red: 0.0, green: 0.8, blue: 1.0)
    static let swatchBlue = Color(red: 0.15, green: 0.35, blue: 1.0)
    // Battery *state* uses Apple system colors (meaning), never the brand green.
    static let batteryFull = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    static let batteryMid = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
    static let batteryLow = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3B / 255)
}

struct PopoverView: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var launchAtLogin: LaunchAtLogin
    /// Settings › Appearance; only the Razer Green glass edge is drawn here. The rest is the
    /// popover's appearance and backdrop, which the app delegate sets.
    @ObservedObject var appearance: AppearanceSettings
    /// Whether to show the card asking for a device test; see `SupportPromptPolicy`.
    @ObservedObject var supportPrompt: SupportPrompt = .shared
    @Environment(\.colorScheme) private var colorScheme
    /// Opening a window is the owner's job — the popover doesn't know about window controllers.
    /// Deliberately not defaulted: a no-op default would let a future call site forget the
    /// handler and ship a gear button that depresses and does nothing, with no compiler error.
    /// The preview passes an explicit `{}`.
    var onOpenSettings: () -> Void
    /// Opens the device test, from the support card or the "Help test it" link on a mouse with
    /// limited support.
    /// Not defaulted, for the same reason as `onOpenSettings`.
    var onOpenDeviceTest: () -> Void

    enum Page { case main, color, buttons, usage, profiles, whatsNew }
    @State private var page: Page = .main
    /// The popover is on screen. Its hosting controller outlives each showing, so views here
    /// stay mounted while it's closed; anything periodic has to check this.
    @State private var isShown = false
    @State private var isAddingProfile = false
    @State private var newProfileName = ""
    @State private var dpiValue: Double = 1600
    @State private var brightnessValue: Double = 100
    /// Local mirror of `controller.lightingColor` — only because `ColorPickerPage` needs a
    /// `Binding<Color>`. The controller's published value is the source of truth (lighting
    /// state is device-confirmed there); this follows it via `onChange`.
    @State private var color: Color = .razerGreen
    /// Recallable custom DPI — persisted per-mouse, and never above the mouse's max.
    @State private var customDPI: Int = 8000
    @State private var editingDpiStage: Int?
    @State private var dpiStageDraft = ""
    @State private var dpiStageError: String?
    @FocusState private var dpiStageFieldFocused: Bool
    @State private var versionHovered = false
    @State private var gearHovered = false
    @State private var tipHovered = false

    private let pollRates = RazerCommands.supportedPollingRates
    private let defaultStages = [400, 800, 1600, 3200, 6400]
    /// The connected mouse's actual configured DPI stages, or sensible defaults.
    private var displayedStages: [Int] {
        controller.dpiStages.isEmpty ? defaultStages : controller.dpiStages
    }
    // Distinct hues with a true red (SwiftUI .red is a warm orange-red; .green duplicated razerGreen).
    // Each carries its spoken/tooltip name.
    private let swatches: [(name: String, color: Color)] = [
        ("Red", .swatchRed),
        ("Orange", Color(red: 1.0, green: 0.5, blue: 0.0)),
        ("Yellow", .swatchYellow),
        ("Green", .razerGreen),
        ("Cyan", .swatchCyan),
        ("Blue", .swatchBlue),
        ("Purple", Color(red: 0.6, green: 0.2, blue: 1.0)),
        ("Pink", Color(red: 1.0, green: 0.2, blue: 0.65)),
    ]

    /// Popover sizes to the MAIN page content (no empty space); sub-pages match that height
    /// (but never less than `subPageMinHeight`). Buttons page scrolls if taller; colour page
    /// is centred.
    private let popoverWidth: CGFloat = 320
    /// With its sections collapsed the main page can be short, and sub-pages that scroll (the
    /// usage charts, the button list) would be squeezed into it. Below this they grow instead.
    /// Not the colour page: it's a fixed-size picker, centred, and would only gain empty space.
    private let subPageMinHeight: CGFloat = 560
    @State private var mainHeight: CGFloat = 0
    /// The corner radius NSPopover gives its body, so the green edge sits on the outline.
    /// Measured from a capture on macOS 26; the content view is exactly the body.
    static let popoverCornerRadius: CGFloat = 10

    var body: some View {
        ZStack {
            switch page {
            case .main: mainPage.transition(.move(edge: .leading))
            case .color: colorPage.transition(.move(edge: .trailing))
            case .buttons: buttonsPage.transition(.move(edge: .trailing))
            case .usage: usagePage.transition(.move(edge: .trailing))
            case .profiles: profilesPage.transition(.move(edge: .trailing))
            case .whatsNew: whatsNewPage.transition(.move(edge: .trailing))
            }
        }
        .frame(width: popoverWidth)
        .frame(height: page == .main ? nil : (mainHeight > 0 ? max(mainHeight, page == .color ? 0 : subPageMinHeight) : nil))
        // While a sub-page is showing, the main page is unmounted and the preference reverts
        // to its 0 default — keep the last real measurement so sub-pages stay locked to the
        // main page's height instead of resizing once the transition finishes.
        .onPreferenceChange(HeightKey.self) { if $0 > 0 { mainHeight = $0 } }
        .animation(.easeInOut(duration: 0.26), value: page)
        .overlay {
            if appearance.look(systemIsDark: colorScheme == .dark).hasGreenEdge {
                // Follows the body's rounded outline; the arrow above it has no edge.
                RoundedRectangle(cornerRadius: Self.popoverCornerRadius)
                    .strokeBorder(Color.razerGreen.opacity(0.45), lineWidth: 1)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        // Closing the popover resets navigation: reopening onto a stale sub-page (whose
        // gating card may have been disabled in the meantime — e.g. Profiles after a
        // disconnect) is disorienting.
        .onAppear { isShown = true }
        .onDisappear { page = .main; isShown = false }
    }

    // MARK: Sub-pages

    private var colorPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ColorPickerPage(color: $color, onBack: { page = .main }) { rgb in
                controller.setStaticColor(rgb)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
    }

    private var buttonsPage: some View {
        // Isolated behind .equatable() so the controller's legitimate periodic publishes
        // (a new battery sample every ~15s while discharging) can't re-render this subtree:
        // a re-render dismisses an open SwiftUI Menu, collapsing the shortcut picker while
        // the user is still choosing. This page only depends on the remapper, whose own
        // publishes (detected buttons, mappings) still update it normally.
        ButtonsPage(controller: controller, remapper: remapper, onBack: { page = .main }).equatable()
    }

    private struct ButtonsPage: View, Equatable {
        let controller: MouseController
        let remapper: ButtonRemapper
        let onBack: () -> Void

        /// The closure is deliberately excluded: it's recreated on every parent render and
        /// always does the same thing (navigate back).
        nonisolated static func == (a: Self, b: Self) -> Bool { a.remapper === b.remapper }

        var body: some View {
            ScrollView {
                RemapView(remapper: remapper, controller: controller, onBack: onBack)
                    .frame(maxWidth: .infinity)
            }
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

    /// ⌘R — the same shortcut the right-click menu's "Refresh Now" shows. Bound once for the
    /// whole main page rather than to a control inside one card, so it works whichever cards
    /// are showing (a mouse without a battery has no battery card and no refresh button).
    private var refreshShortcut: some View {
        Button("Refresh") { controller.refreshAll() }
            .keyboardShortcut("r")
            .disabled(controller.isRefreshing)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerCard
            if let pid = supportCardPID { supportCard(pid) }
            if let version = updateChecker.latestVersion { updateCard(version) }
            // Never both: an update waiting to be installed is the more useful thing to say
            // than one that already was.
            else if updateChecker.justUpdatedTo != nil { updatedCard }
            // A Razer mouse on Bluetooth can't be controlled (no control protocol over BT) —
            // explain it instead of just showing "offline".
            if controller.bluetoothMouse != nil && !controller.connected { bluetoothNotice }
            if noMouse {
                // A last reading is still worth showing (the snapshot is persisted, so most
                // returning users have one); the empty-state card still says what to do.
                if controller.lastBatterySnapshot != nil { batteryCard.opacity(0.55) }
                noMouseCard
            } else {
                // Battery stays readable (last-known) but dims when offline; its refresh button
                // stays active so you can retry.
                if controller.deviceHasBattery {
                    batteryCard.opacity(controller.connected ? 1 : 0.55)
                }
                // Live mouse-config sections: dim AND disable while disconnected.
                dpiCard
                    .disabled(!controller.connected)
                    .opacity(controller.connected ? 1 : 0.45)
                // Dims with DPI, but its rows still open and close offline so the last-known
                // settings stay readable; the controls inside them (and the Buttons page,
                // which needs the mouse) are what's disabled.
                settingsGroup
                    .opacity(controller.connected ? 1 : 0.45)
            }
            footer
        }
        .padding(12)
        .frame(width: popoverWidth)
        .background(refreshShortcut)
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        .onAppear {
            if controller.dpi != 0 { dpiValue = Double(controller.dpi) }
            brightnessValue = Double(controller.brightness)
            if let timeout = controller.sleepTimeout { sleepTimeoutValue = Double(timeout) }
            loadCustomDPI()
            color = controller.lightingColor.swiftUIColor
        }
        .onChange(of: controller.lightingColor) { _, new in color = new.swiftUIColor }
        .onChange(of: controller.dpi) { _, new in if new != 0 { dpiValue = Double(new) } }
        .onChange(of: controller.brightness) { _, new in brightnessValue = Double(new) }
        // A failed device write leaves the controller's values unchanged, so no value-driven
        // onChange fires — snap the optimistic slider state back to reality explicitly.
        .onChange(of: controller.lastWriteFailure) { _, _ in
            if controller.dpi != 0 { dpiValue = Double(controller.dpi) }
            brightnessValue = Double(controller.brightness)
            if let timeout = controller.sleepTimeout { sleepTimeoutValue = Double(timeout) }
        }
        // A half-typed profile name shouldn't survive its row closing and reappear later.
        .onChange(of: expandedSections.contains(.profiles)) { _, open in
            if !open { isAddingProfile = false }
        }
        // …or when the row disappears instead of closing (a mouse without profiles).
        .onChange(of: controller.supportsProfiles) { _, supported in
            if !supported { isAddingProfile = false }
        }
        .onChange(of: controller.deviceKey) { _, _ in loadCustomDPI() } // reload/clamp per mouse
        .onChange(of: controller.deviceMaxDPI) { _, _ in loadCustomDPI() }
        .onChange(of: controller.sleepTimeout) { _, new in if let new { sleepTimeoutValue = Double(new) } }
    }

    /// No mouse is known at all: never seen this session, or unplugged (which forgets its
    /// name). Not a sleeping or out-of-range one, which keeps its name and its dimmed
    /// controls. With no model to describe, those controls would be placeholders for a mouse
    /// that isn't there — every card disabled, the DPI chips showing defaults — so the page
    /// shows one card that says what to do, the way Control Center's Bluetooth module does
    /// with nothing paired.
    private var noMouse: Bool {
        !controller.connected && controller.deviceName == nil && controller.bluetoothMouse == nil
    }

    private var noMouseCard: some View {
        card {
            VStack(spacing: 8) {
                Image(systemName: "computermouse")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(needsPermission ? "MacRazer can't see your mouse yet" : "No Razer mouse found")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(needsPermission
                     ? "It needs Input Monitoring permission to talk to the mouse."
                     : "Plug in the wireless dongle or a USB cable, or move the mouse to wake it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if needsPermission {
                    Button {
                        AppDelegate.openInputMonitoringSettings()
                    } label: {
                        Label("Grant Input Monitoring…", systemImage: "lock.shield")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.razerGreenText)
                } else {
                    Button {
                        controller.refreshAll()
                    } label: {
                        Text(controller.isRefreshing ? "Looking…" : "Look Again")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(controller.isRefreshing)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    private var supportsBasiliskBluetooth: Bool {
        controller.deviceIsBluetooth
            && controller.deviceID.map(RazerDevices.supportsStageEditing(pid:)) == true
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
                    Text(controller.deviceName ?? controller.bluetoothMouse?.name
                         ?? controller.lastBatterySnapshot?.deviceName ?? "No mouse connected")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(headerSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let ct = connectionType { connectionChip(ct) }
                    }
                    // Only where it helps: an unverified mouse. A verified one reaches the same
                    // test from the right-click menu, without the popover asking every time.
                    // The support card below says the same thing louder; once it's hidden or
                    // a report went out, this stays as the quiet way back.
                    if controller.connected && !controller.deviceSupported && supportCardPID == nil {
                        Button(action: onOpenDeviceTest) {
                            HStack(spacing: 3) {
                                Text("Help test it")
                                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.razerGreenText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                Circle()
                    .fill(controller.connected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(controller.connected ? "Connected" : "Not connected")
            }
        }
    }

    /// The unverified mouse the support card is for, or nil when there's no card to show. Not
    /// over Bluetooth: the device test runs over the cable or dongle only.
    private var supportCardPID: Int? {
        guard controller.connected, !controller.deviceSupported, !controller.deviceIsBluetooth,
              let pid = controller.deviceID, supportPrompt.showsCard(pid: pid) else { return nil }
        return pid
    }

    private func supportCard(_ pid: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checklist")
                    .foregroundStyle(Color.razerGreenText)
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Help us support this mouse").font(.system(size: 12, weight: .semibold))
                    Text("A 2-minute test shows us what it can do. You review the report before it's sent.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Hide") { supportPrompt.markDeclined(pid: pid) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Hide this card. \"Help test it\" stays under the mouse name.")
                Button("Run the Test", action: onOpenDeviceTest)
                    .buttonStyle(RazerProminentButtonStyle())
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.razerGreenText.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.razerGreenText.opacity(0.28)))
    }

    private var headerSubtitle: String {
        switch controller.bluetoothRecoveryState {
        case .reconnecting where !controller.connected: return "Reconnecting…"
        default: break
        }
        if controller.connected { return controller.deviceSupported ? "Connected" : "Connected · limited support" }
        if controller.bluetoothMouse != nil { return "On Bluetooth" }
        if controller.deviceName != nil { return "Offline" }
        return "Connect a Razer mouse"
    }

    /// The active control transport, shown as a small chip beside "Connected". Resolved from
    /// the registry — the PID identifies the link (wireless models enumerate under a
    /// different PID when cabled). The old `charging ⇒ wired` heuristic mislabeled every
    /// wired-only mouse as "2.4 GHz", since a wired mouse never reports charging.
    /// Bluetooth only reads "Connected" for models with Bluetooth control; any other Razer
    /// mouse on Bluetooth is surfaced separately (`bluetoothNotice`).
    private var connectionType: ConnectionChip? {
        guard controller.connected else { return nil }
        switch RazerDevices.connection(pid: controller.deviceID) {
        case .bluetooth:
            // Blue, the colour macOS and the mouse itself use for Bluetooth, so the link
            // reads at a glance as different from the green USB ones. A stronger fill than
            // theirs, or the blue is hard to read on the dark background.
            return ConnectionChip(symbol: "dot.radiowaves.left.and.right", label: "Bluetooth",
                                  tint: .bluetoothBlue, fillOpacity: 0.3)
        case .wired:
            return ConnectionChip(symbol: "cable.connector", label: "Wired")
        case .wirelessDongle:
            // `charging` implies a USB-C cable is attached, even though control still
            // flows through the dongle's PID.
            return controller.charging
                ? ConnectionChip(symbol: "cable.connector", label: "Wired")
                : ConnectionChip(symbol: "antenna.radiowaves.left.and.right", label: "2.4 GHz")
        case nil:
            // Unknown model: "USB" is true for both a cable and a dongle.
            return ConnectionChip(symbol: "cable.connector", label: "USB")
        }
    }

    /// How a link's chip looks: green for the USB links, blue for Bluetooth.
    private struct ConnectionChip {
        let symbol: String
        let label: String
        var tint: Color = .razerGreenText
        var fillOpacity: Double = 0.15
    }

    private func connectionChip(_ ct: ConnectionChip) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ct.symbol).font(.system(size: 8.5, weight: .bold))
            Text(ct.label).font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(ct.tint)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(ct.tint.opacity(ct.fillOpacity), in: Capsule())
    }

    /// Shown when a Razer mouse is on Bluetooth but not under control: either a model with no
    /// Bluetooth control (switch modes), or a supported one MacRazer can't reach right now.
    private var bluetoothNoticeText: String {
        switch controller.bluetoothMouse {
        case .accessDenied(let name):
            return "\(name) can be controlled over Bluetooth, but MacRazer isn't allowed to use Bluetooth. Turn it on in System Settings → Privacy & Security → Bluetooth."
        case .connecting(let name):
            return "MacRazer couldn't reach \(name) over Bluetooth yet. It will keep trying."
        case .needsModeSwitch(let name):
            return "\(name) only reports battery, DPI and lighting over the 2.4 GHz dongle or USB-C, not over Bluetooth. Switch its mode to use MacRazer."
        case nil:
            return ""
        }
    }

    private var bluetoothNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.batteryMid)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Connected via Bluetooth").font(.system(size: 12, weight: .semibold))
                Text(bluetoothNoticeText)
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

    /// Quick-switch chips, shown when the Profiles row is expanded: a chip per saved profile
    /// (filled green when active) plus a "+" chip to save the current setup. Switching never
    /// needs a page navigation; only the rarely-needed rename/delete flow lives behind
    /// "Manage Profiles…".
    private var profilesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.profiles.isEmpty && !isAddingProfile {
                HStack(spacing: 8) {
                    Text("Save your current setup as a profile")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    addProfileChip
                }
            } else {
                // Wraps to new rows — a plain HStack overflows the fixed-width popover
                // once a handful of profiles exist.
                FlowLayout(spacing: 6) {
                    ForEach(controller.profiles) { profileChip($0) }
                    if !isAddingProfile { addProfileChip }
                }
            }
            if isAddingProfile { addProfileField }
            if controller.profileApplyFailed {
                Text("Couldn't apply that. The mouse isn't responding.")
                    .font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            }
            if !controller.profiles.isEmpty {
                Button("Manage Profiles…") { page = .profiles }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.razerGreenText)
            }
        }
    }

    private func profileChip(_ profile: MouseProfile) -> some View {
        let active = profile.id == controller.activeProfileID
        return Button {
            // Local effect/color state follows via the activeProfileID onChange once the
            // apply actually succeeds — nothing optimistic here.
            controller.applyProfile(profile, remapper: remapper)
        } label: {
            Text(profile.name)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: active ? .semibold : .regular))
        .foregroundStyle(active ? Color.onRazerGreen : Color.secondary)
        .frame(height: 24)
        .background(active ? Color.razerGreen : Color.primary.opacity(0.08), in: Capsule())
        .hoverHighlight(Capsule())
        .lineLimit(1)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Default name that never collides with an existing profile (count+1 repeats after
    /// deletions).
    private var suggestedProfileName: String {
        let names = Set(controller.profiles.map(\.name))
        var i = controller.profiles.count + 1
        while names.contains("Profile \(i)") { i += 1 }
        return "Profile \(i)"
    }

    private var addProfileChip: some View {
        Button {
            newProfileName = suggestedProfileName
            isAddingProfile = true
        } label: {
            // The circle is part of the label, so the whole of it takes the click, not just
            // the glyph a plain button would otherwise hit-test.
            Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.razerGreenText)
                .frame(width: 24, height: 24)
                .background(Color.razerGreen.opacity(0.12), in: Circle())
                .overlay(Circle().stroke(Color.razerGreen.opacity(0.55), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // dpi == 0 = the first settings read hasn't landed yet; a snapshot taken now
        // would save a profile that later applies as 100 DPI.
        .disabled(controller.dpi == 0)
        .help(controller.dpi == 0 ? "Waiting for the mouse's current settings…" : "Save current setup as a profile")
    }

    private var addProfileField: some View {
        HStack(spacing: 6) {
            TextField("Profile name", text: $newProfileName, onCommit: saveNewProfile)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            Button("Save", action: saveNewProfile)
                .buttonStyle(RazerProminentButtonStyle())
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
        controller.saveCurrentAsProfile(name: name, remapper: remapper)
        isAddingProfile = false
    }

    // MARK: Update notice

    private func updateCard(_ version: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.razerGreenText)
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available").font(.system(size: 12, weight: .semibold))
                    Text("Version \(version) is out. You're on \(appVersion).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // No way out mid-install: dismissing wouldn't stop the swap, it would just
                // hide the only thing telling the user what's happening.
                if !updateChecker.isBusy {
                    Button {
                        updateChecker.dismiss(version)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Skip this version")
                    .accessibilityLabel("Skip version \(version)")
                }
            }
            if let error = updateChecker.downloadError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            }
            // A row, not the notes. The main page is already at the height a menu bar
            // popover can use; the notes get their own page rather than competing with the
            // seven cards above them.
            if updateChecker.phase == .idle, !updateChecker.latestNotes.isEmpty {
                Button { page = .whatsNew } label: {
                    HStack(spacing: 6) {
                        Text("What's new in \(version)").font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.razerGreenText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            switch updateChecker.phase {
            case .idle: updateActionButton
            case .downloading(let fraction): updateProgress(fraction)
            case .installing: updateBusyLabel("Installing…")
            case .restarting: updateBusyLabel("Restarting…")
            case .needsRestart: updateNeedsRestart
            }
            // After a failed in-place install the manual route still works — offer it rather
            // than leaving "install it manually" as advice with no button attached.
            if updateChecker.downloadError != nil, !updateChecker.isBusy, updateChecker.canInstallInPlace {
                Button("Download the DMG instead") {
                    Task { await updateChecker.downloadAndOpenDMG() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.razerGreenText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.razerGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
    }

    /// One click for the whole thing where that's possible; the old "fetch the DMG and let the
    /// user drag it across" wording where it isn't, so the button never promises a restart it
    /// can't deliver.
    private var updateActionButton: some View {
        Button {
            Task { await updateChecker.downloadAndInstall() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: updateChecker.canInstallInPlace ? "arrow.triangle.2.circlepath" : "arrow.down.to.line")
                Text(updateChecker.canInstallInPlace ? "Update & Restart" : "Download")
            }
            .font(.system(size: 11.5, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
        }
        .buttonStyle(RazerProminentButtonStyle())
        .controlSize(.small)
    }

    /// The release notes, given the whole popover. Reached from the update card's one row.
    ///
    /// The empty fallback is unreachable today — the row that navigates here is gated on the
    /// same `latestNotes` — but it still renders the page rather than nothing, so a future
    /// call site can at worst produce a thin page with a working back button, never a blank
    /// dead end.
    private var whatsNewPage: some View {
        // Reached from either card, and they are about different releases: one waiting, one
        // already running. An update on offer wins, matching which card is showing.
        let pending = updateChecker.latestVersion
        return WhatsNewPage(version: pending ?? appVersion,
                            releases: pending != nil ? updateChecker.latestNotes
                                                     : updateChecker.installedNotes,
                            canInstallInPlace: updateChecker.canInstallInPlace,
                            // Nothing to install when the notes are about what's already
                            // running, so the page shows no button at all rather than one that
                            // would re-download the version you are reading about.
                            onBack: { page = .main },
                            onUpdate: pending == nil ? nil : {
                                page = .main
                                Task { await updateChecker.downloadAndInstall() }
                            })
    }

    /// Shown after the version changes, until dismissed.
    ///
    /// With automatic installs on there is no update card and never was one — this is the only
    /// place the app says a release happened. It is a row and a dismiss, because it is news
    /// rather than a decision.
    ///
    /// Takes no version: `justUpdatedTo` carries the *comparable* version, which is "0" for an
    /// unversioned dev build, and "Updated to 0" is not a sentence. It always describes the
    /// running build, so `appVersion` is both correct and the one worth showing.
    private var updatedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.razerGreenText)
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Updated to \(appVersion)").font(.system(size: 12, weight: .semibold))
                    Text("You're on the latest version.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    updateChecker.dismissAnnouncement()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            if !updateChecker.installedNotes.isEmpty {
                Button { page = .whatsNew } label: {
                    HStack(spacing: 6) {
                        Text("What's new in \(appVersion)").font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.razerGreenText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.razerGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
    }

    private func updateProgress(_ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(.razerGreen)
            Text("Downloading… \(Int(fraction * 100))%")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    /// The update is on disk but the relaunch didn't take. Say so plainly and give the one
    /// action that finishes it — not the error-and-retry treatment a failed install gets.
    private var updateNeedsRestart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Update installed. Quit and reopen MacRazer to use it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Quit MacRazer") { NSApplication.shared.terminate(nil) }
                .buttonStyle(RazerProminentButtonStyle())
                .controlSize(.small)
                .font(.system(size: 11.5, weight: .medium))
        }
    }

    private func updateBusyLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        .foregroundStyle(controller.batteryPercent ?? 100 < Battery.lowThresholdPercent ? Color.batteryLow : .primary)
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
            // Offline and on screen, re-rendered every 30 s so the "· 2 min. ago" age keeps up:
            // nothing else republishes while the mouse is away. Otherwise no timer at all, so a
            // closed popover never wakes the app.
            if isShown && !controller.connected {
                TimelineView(.periodic(from: .now, by: 30)) { _ in batterySubtitleText }
            } else {
                batterySubtitleText
            }
            // With no mouse at all, `noMouseCard` below carries this button instead.
            if needsPermission && !noMouse {
                Button {
                    AppDelegate.openInputMonitoringSettings()
                } label: {
                    Label("Grant Input Monitoring…", systemImage: "lock.shield")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.razerGreenText)
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

    private var batterySubtitleText: some View {
        Text(batterySubtitle).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var batterySubtitle: String {
        if !controller.connected {
            if let snapshot = controller.lastBatterySnapshot {
                let age = LastBatterySnapshot.relativeAgeFormatter.localizedString(for: snapshot.observedAt, relativeTo: Date())
                if snapshot.wasCharging { return "Last reading: \(snapshot.percent)% · charging · \(age)" }
                if let estimate = snapshot.shortEstimateText {
                    return "\(estimate) · \(age)"
                }
                return "Last reading: \(snapshot.percent)% · \(age) · no estimate yet"
            }
            switch controller.bluetoothMouse {
            case .needsModeSwitch: return "On Bluetooth. Use 2.4 GHz or USB-C"
            case .connecting: return "On Bluetooth. Connecting…"
            case .accessDenied: return "On Bluetooth. Needs Bluetooth access"
            case nil: break
            }
            if needsPermission { return "Needs Input Monitoring permission" }
            return "Disconnected. Wake the mouse and refresh"
        }
        if controller.charging { return "Charging" }
        if let est = controller.timeEstimate { return est }
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
        .accessibilityLabel("Battery usage history")
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
        .help(controller.supportsPollRate ? "Refresh battery, DPI and polling rate (⌘R)" : "Refresh battery and DPI (⌘R)")
        .accessibilityLabel("Refresh")
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
            if controller.supportsFreeDPI {
                Slider(value: $dpiValue, in: 100...Double(controller.deviceMaxDPI), step: 50) { editing in
                    if !editing {
                        let v = Int(dpiValue)
                        controller.setDPI(v)
                        if !displayedStages.contains(v) { saveCustomDPI(v) } // remember the manual value
                    }
                }
                .tint(.razerGreen)
                .controlSize(.small)
            }
            HStack(spacing: 6) {
                ForEach(Array(displayedStages.enumerated()), id: \.offset) { index, value in
                    dpiChip(value, index: index)
                }
                if controller.supportsFreeDPI { customChip }
            }
            if let dpiStageError {
                Text(dpiStageError).font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            } else if let error = controller.dpiStagesError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            }
        }
        }
    }

    /// A fixed-preset DPI chip.
    private func dpiChip(_ value: Int, index: Int) -> some View {
        let activeStageIndex = controller.activeDpiStage.flatMap { stage in
            displayedStages.indices.contains(stage) && displayedStages[stage] == Int(dpiValue) ? stage : nil
        }
        let active = activeStageIndex.map { $0 == index } ?? (Int(dpiValue) == value)
        let accent = DPIStageAccent.forStage(at: index)
        let editing = editingDpiStage == index
        return Group {
            if editing {
                TextField("DPI", text: $dpiStageDraft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .focused($dpiStageFieldFocused)
                    .onSubmit { commitDpiStage(index: index) }
                    .onAppear { dpiStageFieldFocused = true }
            } else {
                Button {
                    dpiValue = Double(value)
                    controller.setDPI(value)
                } label: {
                    // Fill the chip so the whole hover-highlighted area is clickable.
                    Text(verbatim: "\(value)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: active ? .semibold : .regular).monospacedDigit())
        // The active stage is a solid fill like every other selected chip; the rest keep the
        // neutral chip and readable secondary text, with the stage hue only as an outline.
        .foregroundStyle(active ? accent.onColor : Color.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(active ? accent.color : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if !active {
                RoundedRectangle(cornerRadius: 6).strokeBorder(accent.color.opacity(0.7), lineWidth: 1)
            }
        }
        .hoverHighlight(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            if supportsBasiliskBluetooth {
                Button("Edit DPI") { beginDpiStageEdit(index: index, value: value) }
            }
        }
        // The stage editor lives in a context menu, which nothing on the chip hints at.
        .help(supportsBasiliskBluetooth ? "Stage \(index + 1) · Right-click to edit" : "Stage \(index + 1)")
        .accessibilityLabel(editing ? "Stage \(index + 1) DPI" : DPIStageAccent.accessibilityLabel(
            value: value, stageIndex: index))
        .accessibilityAddTraits(active ? .isSelected : [])
        .disabled(controller.isUpdatingDpiStages || (editingDpiStage != nil && !editing))
    }

    private func beginDpiStageEdit(index: Int, value: Int) {
        guard supportsBasiliskBluetooth, !controller.isUpdatingDpiStages else { return }
        dpiStageError = nil
        dpiStageDraft = String(value)
        editingDpiStage = index
        dpiStageFieldFocused = true
    }

    private func commitDpiStage(index: Int) {
        guard editingDpiStage == index else { return }
        defer { editingDpiStage = nil; dpiStageFieldFocused = false }
        guard let value = Int(dpiStageDraft.trimmingCharacters(in: .whitespaces)),
              (100...controller.deviceMaxDPI).contains(value) else {
            dpiStageError = "DPI must be between 100 and \(controller.deviceMaxDPI)."
            return
        }
        guard controller.dpiStages.indices.contains(index), controller.dpiStages[index] != value else { return }
        dpiStageError = nil
        controller.setDPIStageValue(value, at: index)
    }

    @State private var sleepTimeoutValue: Double = 300

    /// The Power Management row's expanded content; the row itself shows the sleep timer.
    private var powerManagementContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "moon.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $sleepTimeoutValue, in: 60...900, step: 15) { editing in
                    if !editing { controller.setSleepTimeout(Int(sleepTimeoutValue)) }
                }
                .tint(.razerGreen)
                .controlSize(.small)
            }
            .disabled(controller.sleepTimeout == nil)
            HStack(spacing: 5) {
                ForEach([60, 120, 300, 600, 900], id: \.self) { value in
                    Button {
                        sleepTimeoutValue = Double(value)
                        controller.setSleepTimeout(value)
                    } label: {
                        Text(formatSleepTimeout(value, compact: true))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: Int(sleepTimeoutValue) == value ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(Int(sleepTimeoutValue) == value ? Color.onRazerGreen : Color.secondary)
                    .frame(maxWidth: .infinity).frame(height: 23)
                    .background(Int(sleepTimeoutValue) == value ? Color.razerGreen : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .hoverHighlight(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Sleep after \(formatSleepTimeout(value))")
                }
            }
            .disabled(controller.sleepTimeout == nil)
            if let error = controller.sleepTimeoutError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            }
        }
    }

    /// Nothing to show until the mouse has reported its value: the slider's starting position
    /// is a placeholder, not the mouse's setting.
    ///
    /// A failed write turns the value red (see the row) rather than replacing it: the mouse's
    /// last confirmed timeout is still the useful thing to show, and the error itself is in
    /// the expanded controls.
    private var sleepTimeoutSummary: String {
        controller.sleepTimeout == nil ? "…" : formatSleepTimeout(Int(sleepTimeoutValue))
    }

    /// "5 min" or "4 min 45 s", the way System Settings words its sleep timers, instead of
    /// "5m 00s". `compact` is for the preset chips, five to a row: "5m".
    private func formatSleepTimeout(_ seconds: Int, compact: Bool = false) -> String {
        let minutes = seconds / 60, rest = seconds % 60
        if compact { return rest == 0 ? "\(minutes)m" : "\(minutes)m\(rest)s" }
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: active ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(active ? Color.onRazerGreen : Color.razerGreenText)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(active ? Color.razerGreen : Color.razerGreen.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(active ? Color.clear : Color.razerGreen.opacity(0.55), lineWidth: 1))
        .hoverHighlight(RoundedRectangle(cornerRadius: 6))
        .help("Your custom DPI. Set it with the slider.")
        .accessibilityLabel("Custom, \(active ? Int(dpiValue) : customDPI) DPI")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// The Polling rate row's expanded content; the row itself shows the current rate.
    private var pollContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(
                get: { displayedPollRate },
                set: { controller.setPollRate($0) }
            )) {
                ForEach(pollRates, id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if let tip = pollRateTip(displayedPollRate) {
                Text(tip)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsPollRateBatteryHint {
                Label("1000 Hz uses the most battery. 500 Hz feels about the same "
                      + "for everyday use.", systemImage: "leaf")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }

    /// The mouse reports 0 when it hasn't answered yet; the card shows that as 1000, the
    /// firmware default, and so does everything that reads it here.
    private var displayedPollRate: Int { controller.pollRate == 0 ? 1000 : controller.pollRate }

    /// What the selected rate is good for. The battery trade-off is only mentioned for a
    /// mouse that has one: on a wired mouse it's a promise about nothing.
    private func pollRateTip(_ hz: Int) -> String? {
        let battery = controller.deviceHasBattery
        switch hz {
        case 1000: return "Smoothest and quickest to respond. Best for gaming."
        case 500: return battery ? "Smooth for everyday work, and easier on the battery."
                                 : "Smooth for everyday work."
        case 125: return battery ? "Lasts longest on a charge. The pointer can feel less smooth, "
                                    + "especially on high refresh rate displays."
                                 : "The pointer can feel less smooth, especially on high "
                                    + "refresh rate displays."
        default: return nil
        }
    }

    /// Same conditions as the lighting hint: a battery mouse, not charging. Reads the raw
    /// `controller.pollRate`, not `displayedPollRate`: 0 means the rate hasn't been read yet,
    /// and advising a switch to 500 Hz on a mouse that may already be there reads as broken.
    private var showsPollRateBatteryHint: Bool {
        controller.deviceHasBattery && !controller.charging && controller.pollRate >= 1000
    }

    /// The Lighting row's expanded content; the row itself shows the effect and brightness.
    private var lightingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            // Bound straight to the controller: setEffect publishes only on a successful
            // device write, so a failed change snaps the picker back by itself — no local
            // state, no suppression flags.
            if controller.supportsLightingEffects {
                Picker("", selection: Binding(get: { controller.effect },
                                              set: { controller.setEffect($0) })) {
                    ForEach(LightingEffect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
            }

            if controller.effect == .staticColor || !controller.supportsLightingEffects {
                HStack(spacing: 7) {
                    ForEach(swatches.indices, id: \.self) { i in
                        swatch(swatches[i].color, name: swatches[i].name)
                    }
                    customColorWell
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }

            if showsLightingBatteryHint {
                Label("Bright lighting drains the battery faster. Around \(Battery.lightingHintBrightnessPercent)% "
                      + "or lower lasts noticeably longer.", systemImage: "leaf")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }

    /// What the collapsed Lighting row says: the effect and brightness, or just the brightness
    /// where effects can't be read (Bluetooth), or "Off".
    private var lightingSummary: String {
        // 0% draws nothing whatever the effect, the same rule `showsLightingBatteryHint` uses.
        if Int(brightnessValue) == 0 { return "Off" }
        if !controller.supportsLightingEffects { return "\(Int(brightnessValue))%" }
        if controller.effect == .off { return "Off" }
        return "\(controller.effect.rawValue) · \(Int(brightnessValue))%"
    }

    /// Reads the local slider value, not `controller.brightness`, so the hint tracks the
    /// thumb while it's dragged rather than appearing only after the write lands. Skipped
    /// while charging (the drain doesn't matter then) and with lighting off (0% or `.off`
    /// both mean the LEDs draw nothing, whatever the slider says).
    private var showsLightingBatteryHint: Bool {
        // Bluetooth can't set or read an effect, only a colour, so `effect` there is left
        // over from USB and says nothing about whether the lights are on.
        controller.deviceHasBattery && !controller.charging
            && (controller.effect != .off || !controller.supportsLightingEffects)
            && Int(brightnessValue) > Battery.lightingHintBrightnessPercent
    }

    /// A real button rather than a tap gesture on a circle, so it reaches VoiceOver and
    /// keyboard navigation, and greys out with the rest of the card while disconnected.
    private func swatch(_ sw: Color, name: String) -> some View {
        Button { controller.setStaticColor(sw.rgb) } label: {
            Circle()
                .fill(sw)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .overlay(Circle().inset(by: -2.5).stroke(Color.primary, lineWidth: isSelected(sw) ? 1.5 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected(sw) ? .isSelected : [])
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
        .help("Pick any colour")
        .accessibilityLabel("Custom colour")
    }

    private func isSelected(_ sw: Color) -> Bool {
        let a = sw.rgb, b = color.rgb
        return a.r == b.r && a.g == b.g && a.b == b.b
    }

    // MARK: Grouped settings

    /// The settings below DPI, each a compact card of its own, the way Control Center lists
    /// its modules. A row shows its current value; the settings rows expand in place to
    /// their controls, each independently of the others, and Buttons opens its page. Which
    /// sections are open is remembered across showings.
    private enum DisclosureSection: String, CaseIterable { case polling, lighting, power, profiles }
    private enum GroupRow: Hashable { case section(DisclosureSection), buttons }
    /// The open sections, comma-separated: `@AppStorage` can't hold a set.
    @AppStorage("popoverExpandedSections") private var expandedSectionsRaw = ""
    private var expandedSections: Set<DisclosureSection> {
        Set(expandedSectionsRaw.split(separator: ",").compactMap { DisclosureSection(rawValue: String($0)) })
    }

    private func toggle(_ section: DisclosureSection) {
        var open = expandedSections
        if open.contains(section) { open.remove(section) } else { open.insert(section) }
        // Written in declaration order so the stored string is stable.
        expandedSectionsRaw = DisclosureSection.allCases.filter { open.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    /// Rows in display order, skipping what this mouse can't do. Profiles come last: they
    /// bundle the rows above them (plus remaps) into presets.
    private var groupRows: [GroupRow] {
        var rows: [GroupRow] = []
        if controller.supportsPollRate { rows.append(.section(.polling)) }
        if controller.deviceHasLighting { rows.append(.section(.lighting)) } // none on e.g. the Atheris
        if supportsBasiliskBluetooth { rows.append(.section(.power)) }
        rows.append(.buttons)
        if controller.supportsProfiles { rows.append(.section(.profiles)) }
        return rows
    }

    private var settingsGroup: some View {
        let rows = groupRows
        // Same 10 pt rhythm as the cards above, so each section reads as its own card.
        return VStack(spacing: 10) {
            // Keyed by row, not position, so a row appearing or vanishing (another mouse, the
            // poll rate turning out to be supported) doesn't shift the others' identity.
            ForEach(rows, id: \.self) { row in
                // Each row is its own card, open or closed, rather than one card split by
                // separators: an open section's controls stay clearly inside their row.
                cardSurface(Group {
                    switch row {
                    case .section(.polling):
                        disclosureRow(.polling, title: "Polling rate", symbol: "timer", tint: .blue,
                                      value: "\(displayedPollRate) Hz") { pollContent }
                    case .section(.lighting):
                        disclosureRow(.lighting, title: "Lighting", symbol: "light.max", tint: .orange,
                                      value: lightingSummary) { lightingContent }
                    case .section(.power):
                        disclosureRow(.power, title: "Power Management", symbol: "moon.zzz", tint: .indigo,
                                      value: sleepTimeoutSummary,
                                      valueColor: controller.sleepTimeoutError == nil ? .secondary : .batteryLow) {
                            powerManagementContent
                        }
                    case .section(.profiles):
                        disclosureRow(.profiles, title: "Profiles", symbol: "person.crop.square.on.square.angled",
                                      tint: .purple, value: profilesSummary,
                                      valueColor: controller.profileApplyFailed ? .batteryLow : .secondary) {
                            profilesContent
                        }
                    case .buttons:
                        Button { page = .buttons } label: {
                            groupRowLabel(title: "Buttons", symbol: "keyboard", tint: .razerGreenText,
                                          value: buttonsSummary,
                                          valueColor: buttonsNeedAccess ? .batteryMid : .secondary,
                                          expanded: false)
                        }
                        .buttonStyle(.plain)
                        .disabled(!controller.connected)
                        .accessibilityLabel("Configure Buttons")
                        .accessibilityValue(buttonsSummary)
                    }
                }
                .frame(maxWidth: .infinity))
            }
        }
    }

    private func disclosureRow<Content: View>(_ section: DisclosureSection, title: String, symbol: String,
                                              tint: Color, value: String, valueColor: Color = .secondary,
                                              @ViewBuilder content: () -> Content) -> some View {
        let expanded = expandedSections.contains(section)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { toggle(section) }
            } label: {
                groupRowLabel(title: title, symbol: symbol, tint: tint, value: value,
                              valueColor: valueColor, expanded: expanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityHint(expanded ? "Collapses the \(title) settings" : "Shows the \(title) settings")
            if expanded {
                content()
                    .disabled(!controller.connected)
                    .padding(.horizontal, 12)
                    // Clear of the header, so a still-highlighted header doesn't sit right on
                    // top of the controls it opened.
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
    }

    /// One row of the group: a tinted icon, the name, the current value and a chevron that
    /// turns down while the row is expanded.
    private func groupRowLabel(title: String, symbol: String, tint: Color, value: String,
                               valueColor: Color, expanded: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11.5)).monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        // The hover wash is an inset rounded shape, like a menu item's or a Control Center
        // row's, rather than an edge-to-edge band: a full-width band ran past the inset
        // separators and read as unfinished. Same 12 × 9 overall padding as before.
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .hoverHighlight(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// Saved remaps do nothing without Accessibility access and the event tap, so the row
    /// says so instead of counting them.
    private var buttonsNeedAccess: Bool {
        !remapper.remappingPermissionsGranted && !remapper.mappings.values.filter { $0 != .passthrough }.isEmpty
    }

    private var buttonsSummary: String {
        if buttonsNeedAccess { return "Needs access" }
        // Resetting a button to "None (default)" stores `.passthrough` rather than removing it.
        let count = remapper.mappings.values.filter { $0 != .passthrough }.count
        return count == 0 ? "" : "\(count) remapped"
    }

    private var profilesSummary: String {
        // A failed apply turns this red (see the row) rather than replacing it, so the row
        // still says which profile is actually active; the error text is in the expanded
        // section.
        if controller.profiles.isEmpty { return "None saved" }
        return controller.profiles.first { $0.id == controller.activeProfileID }?.name ?? "None active"
    }

    // MARK: Footer

    private var appVersion: String { AppInfo.displayVersion }

    private var footer: some View {
        HStack(spacing: 4) {
            Link(destination: ProjectLinks.site) {
                Text(verbatim: "v\(appVersion)")
                    .font(.system(size: 11))
                    // Nothing at rest marks it as a link — the footer should stay quiet — so
                    // hover has to carry the whole affordance: colour and underline together,
                    // since colour alone is easy to miss at 11pt in tertiary grey.
                    .foregroundStyle(versionHovered ? AnyShapeStyle(Color.razerGreenText) : AnyShapeStyle(.tertiary))
                    .underline(versionHovered)
            }
            .buttonStyle(.plain)
            .onHover { versionHovered = $0 }
            .help("Open the MacRazer website")
            Text(verbatim: "· unofficial").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            // One quiet icon, never a banner: the popover is where people spend their time,
            // and anything louder here would read as nagging.
            Link(destination: ProjectLinks.tip) {
                Image(systemName: tipHovered ? "heart.fill" : "heart")
                    .font(.system(size: 12.5))
                    .foregroundStyle(tipHovered ? AnyShapeStyle(Color.razerGreenText) : AnyShapeStyle(.secondary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { tipHovered = $0 }
            .help("Leave a tip: MacRazer is free and built in spare time")
            .accessibilityLabel("Leave a tip")
            .padding(.trailing, 8)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    // Same hover treatment as the version link beside it — a footer this
                    // quiet needs the cue, and two different ones would be noise.
                    .foregroundStyle(gearHovered ? AnyShapeStyle(Color.razerGreenText) : AnyShapeStyle(.secondary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { gearHovered = $0 }
            .help("MacRazer settings (⌘,)")
            .accessibilityLabel("Settings")
            // The same shortcut as the right-click menu's "Settings…", and every Mac app's.
            .keyboardShortcut(",")
            .padding(.trailing, 6)
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

extension RGB {
    /// The device triple as a SwiftUI color (inverse of `Color.rgb`).
    var swiftUIColor: Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

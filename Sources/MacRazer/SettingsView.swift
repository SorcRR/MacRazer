// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// One page of the Settings window, picked in its sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, privacy, appearance, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .privacy: return "Privacy"
        case .appearance: return "Appearance"
        case .updates: return "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .privacy: return "hand.raised.fill"
        case .appearance: return "circle.lefthalf.filled"
        case .updates: return "arrow.down"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(nsColor: .systemGray)
        case .privacy: return Color(nsColor: .systemBlue)
        case .appearance: return Color(nsColor: .systemPurple)
        case .updates: return Color(nsColor: .systemGreen)
        }
    }
}

/// App-level settings, in a real window rather than another card in the popover.
///
/// The popover is for the *mouse* — DPI, polling, lighting, battery. These are settings for
/// MacRazer itself, they're set once and rarely revisited, and they need room to explain
/// themselves (what "install automatically" actually does, why the login item is unavailable
/// from a mounted disk image).
///
/// A sidebar of pages, like System Settings, in a window that keeps one size whichever page is
/// showing. All of it stacked in one column ran taller than a small laptop screen.
struct SettingsView: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var launchAtLogin: LaunchAtLogin
    @ObservedObject var updateChecker: UpdateChecker
    /// Closes the window, for Escape and ⌘W. Not optional, for the same reason as
    /// `AboutView.onDone`: a defaulted no-op ships shortcuts that do nothing and compiles fine.
    var onDone: () -> Void
    /// Called when "install automatically" is switched, so the owner can act on an update that
    /// is *already* known — the one moment the user is watching for the setting to do
    /// something, and the moment none of the other triggers fire.
    var onAutoInstallChanged: (() -> Void)?
    /// The crash window's "Don't Ask Again" writes the same key, so this is how to undo it.
    @AppStorage(CrashLogScanner.offerKey) private var offerCrashReports = true
    @ObservedObject var appearance: AppearanceSettings = .shared
    @ObservedObject var usageStats: UsageStats = .shared
    @ObservedObject var supportPrompt: SupportPrompt = .shared
    @State var pane: SettingsPane = .general
    @State private var confirmingDelete = false
    @State private var hoveredPane: SettingsPane?
    @State private var tipHovered = false

    /// The window's one size. Fixed so switching pages doesn't make the window jump; a page
    /// with more than fits scrolls instead.
    static let size = CGSize(width: 780, height: 540)
    private static let sidebarWidth: CGFloat = 210
    /// The title bar's height. The content runs up under it, so the sidebar can start under
    /// the traffic lights and the page title can sit level with them.
    private static let titleBarHeight: CGFloat = 52

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .ignoresSafeArea()
        .background(closeShortcuts)
        // The login switch mirrors the system's registration, which the user can change in
        // System Settings while this window sits open in the background.
        .onAppear { launchAtLogin.refresh() }
    }

    /// Privacy only exists in a build that can send stats: see `WorkerEndpoint`.
    private var panes: [SettingsPane] {
        SettingsPane.allCases.filter { $0 != .privacy || usageStats.isAvailable }
    }

    /// The page actually shown: one the sidebar lists, so a `pane` passed in for a page this
    /// build doesn't have falls back to General rather than showing a page with no entry.
    private var shownPane: SettingsPane {
        panes.contains(pane) ? pane : .general
    }

    /// The window has no Done button any more, as macOS settings windows don't: changes apply
    /// as they're made. These keep the keyboard ways out. ⌘W needs its own, because a menu bar
    /// app has no File menu to supply it.
    private var closeShortcuts: some View {
        ZStack {
            Button("Close", action: onDone).keyboardShortcut(.cancelAction)
            Button("Close", action: onDone).keyboardShortcut("w")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(panes) { sidebarItem($0) }
            Spacer(minLength: 12)
            tipButton
            Text("Free, and built in spare time.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 8)
            versionFooter
        }
        .padding(.top, Self.titleBarHeight)
        .padding([.horizontal, .bottom], 10)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.04))
        // The window is kept when closed, and closing it under the pointer never sends the
        // hover's end: without this the item would still be lit when Settings reopens.
        .onDisappear { hoveredPane = nil; tipHovered = false }
    }

    private func sidebarItem(_ item: SettingsPane) -> some View {
        let selected = shownPane == item
        return Button {
            pane = item
        } label: {
            HStack(spacing: 9) {
                iconChip(item.symbol, tint: item.tint, size: 22)
                Text(item.title).font(.system(size: 13))
                Spacer(minLength: 0)
                // Same signal as the dot on the menu bar icon, on the page that can act on it.
                // Only while there's something to do: once an install starts, the footer
                // below shows where it stands instead.
                if item == .updates, updateChecker.latestVersion != nil, !updateChecker.isBusy {
                    Text("1")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.razerGreen, in: Capsule())
                        .accessibilityLabel("Update available")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
            .background(Color.primary.opacity(selected ? 0.10 : hoveredPane == item ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hoveredPane = $0 ? item : (hoveredPane == item ? nil : hoveredPane) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var tipButton: some View {
        Link(destination: ProjectLinks.tip) {
            HStack(spacing: 7) {
                Image(systemName: "heart.fill").foregroundStyle(Color(nsColor: .systemPink))
                Text("Leave a Tip").foregroundStyle(.primary)
            }
            .font(.system(size: 12.5, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(tipHovered ? 0.11 : 0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(tipHovered ? 0.16 : 0.10)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { tipHovered = $0 }
        .help("MacRazer is free and built in spare time")
    }

    /// What's installed and where updating stands, always the same three lines high — version,
    /// status, and a slot for an action, empty when there's nothing to do — so the tip button
    /// above it never moves as the state changes.
    private var versionFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(updateChecker.phase == .needsRestart
                     ? "MacRazer \(updateChecker.latestVersion ?? updateChecker.currentVersion) installed"
                     : "MacRazer \(updateChecker.currentVersion)")
                    .font(.system(size: 11.5, weight: .medium))
                footerStatus
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            footerAction
                .frame(height: 24, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider() }
    }

    /// The phase first: a background check can run during any of them, and "Checking…" must
    /// not cover "Quit and reopen", the one instruction left to give.
    @ViewBuilder private var footerStatus: some View {
        switch updateChecker.phase {
        case .downloading(let f):
            Text("Downloading \(updateChecker.latestVersion ?? "update")… \(Int(f * 100))%")
                .foregroundStyle(.secondary)
        case .installing: Text("Installing…").foregroundStyle(.secondary)
        case .restarting: Text("Restarting…").foregroundStyle(.secondary)
        case .needsRestart: Text("Quit and reopen to use it.").foregroundStyle(.secondary)
        case .idle:
            if updateChecker.isChecking {
                Text("Checking…").foregroundStyle(.secondary)
            } else if updateChecker.downloadError != nil {
                Text("The update didn't install.").foregroundStyle(Color.batteryLow)
            } else if let latest = updateChecker.latestVersion {
                HStack(spacing: 5) {
                    Circle().fill(Color.razerGreenBright).frame(width: 6, height: 6)
                    Text("\(latest) is available")
                }
                .foregroundStyle(Color.razerGreenText)
            } else {
                Text("Up to date").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var footerAction: some View {
        switch updateChecker.phase {
        case .downloading(let f):
            ProgressView(value: f).progressViewStyle(.linear).tint(.razerGreen)
        case .installing, .restarting:
            ProgressView().progressViewStyle(.linear).tint(.razerGreen)
        case .needsRestart:
            // Not "Restart": the app already tried to start the new copy and couldn't, which
            // is how it got here. Quitting is the one step left that the user has to take.
            Button("Quit MacRazer") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        case .idle:
            // Up to date leaves the slot empty: checking by hand is on the Updates page. A
            // failed install still gets a way to try again from here.
            if updateChecker.latestVersion != nil {
                installButton
            } else if updateChecker.downloadError != nil {
                checkNowButton
            }
        }
    }

    /// "Download" where the app can't replace itself: the same call then fetches the DMG and
    /// opens it, so the button never promises an install it can't do.
    private var installButton: some View {
        Button(updateChecker.canInstallInPlace ? "Install Now" : "Download") {
            Task { await updateChecker.downloadAndInstall() }
        }
        .controlSize(.small)
        .buttonStyle(RazerProminentButtonStyle())
    }

    private var checkNowButton: some View {
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

    // MARK: Pages

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(shownPane.title)
                .font(.system(size: 20, weight: .semibold))
                .frame(height: Self.titleBarHeight, alignment: .bottom)
                .padding(.horizontal, 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch shownPane {
                    case .general: generalPage
                    case .privacy: privacyPage
                    case .appearance: appearancePage
                    case .updates: updatesPage
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var generalPage: some View {
        settingsGroup("Startup") {
            launchAtLoginRow
        }
        settingsGroup("Menu bar and sounds") {
            // Hidden rather than disabled for a mouse with no battery: there is no
            // percentage to show, so the switch would be a promise about nothing.
            if controller.deviceHasBattery {
                batteryPercentRow
                rowDivider
            }
            connectionSoundsRow
        }
        settingsGroup("Helping out") {
            // Hidden while there's nowhere to send a report; see `CrashReporting`.
            if CrashReporting.isAvailable {
                crashReportsRow
                rowDivider
            }
            supportPromptRow
        }
    }

    @ViewBuilder private var privacyPage: some View {
        settingsGroup {
            mouseModelsRow
            rowDivider
            usageStatsRow
        }
        settingsGroup {
            deleteDataRow
        }
    }

    @ViewBuilder private var appearancePage: some View {
        settingsGroup {
            themeRow
            rowDivider
            glassRow
        }
    }

    @ViewBuilder private var updatesPage: some View {
        settingsGroup {
            autoInstallRow
            rowDivider
            versionRow
        }
    }

    // MARK: Rows

    private var launchAtLoginRow: some View {
        settingRow(
            symbol: "power", tint: Color(nsColor: .systemGray),
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
            symbol: "speaker.wave.2.fill", tint: Color(nsColor: .systemPink),
            title: "Connection sounds",
            detail: "Play a sound when the mouse connects or disconnects.",
            isOn: Binding(get: { controller.connectionSoundsEnabled },
                          set: { controller.connectionSoundsEnabled = $0 })
        )
    }

    private var batteryPercentRow: some View {
        settingRow(
            symbol: "battery.75percent", tint: Color(nsColor: .systemGreen),
            title: "Show battery % in menu bar",
            detail: "Off leaves just the mouse icon, which takes less room in a crowded menu bar.",
            isOn: Binding(get: { controller.showPercentInMenuBar },
                          set: { controller.showPercentInMenuBar = $0 })
        )
    }

    /// A compact segmented control of its own beside the text, as in the design: the system one
    /// is wide enough there to leave the note one word wide.
    private var themeRow: some View {
        HStack(alignment: .center, spacing: 12) {
            iconChip("circle.lefthalf.filled", tint: Color(nsColor: .systemPurple))
            VStack(alignment: .leading, spacing: 2) {
                Text("Theme").font(.system(size: 13, weight: .medium))
                sectionNote("System follows macOS. Razer Green is always dark.")
            }
            Spacer(minLength: 8)
            themeSegments
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var themeSegments: some View {
        HStack(spacing: 2) {
            ForEach(PopoverTheme.allCases) { theme in
                let on = appearance.theme == theme
                Button { appearance.theme = theme } label: {
                    Text(theme.title)
                        .font(.system(size: 12))
                        .foregroundStyle(on ? Color.primary : Color.primary.opacity(0.75))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(on ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.14)))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme")
    }

    private var glassRow: some View {
        settingRow(
            symbol: "drop.halffull", tint: Color(nsColor: .systemTeal),
            title: "Glass effect",
            detail: "The popover and windows let the desktop show through. Off gives a solid "
                + "background, which is easier to read over busy windows.",
            isOn: $appearance.glass
        )
    }

    private var crashReportsRow: some View {
        settingRow(
            symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemOrange),
            title: "Offer to send crash reports",
            detail: "If MacRazer quits unexpectedly, ask next time whether to send a report. "
                + "You see exactly what's in it first.",
            isOn: $offerCrashReports
        )
    }

    private var supportPromptRow: some View {
        settingRow(
            symbol: "computermouse.fill", tint: Color(nsColor: .systemBlue),
            title: "Ask me to help test my mouse",
            detail: "When a Razer mouse connects that MacRazer doesn't fully support, or that still "
                + "needs a test on another connection, ask whether to run a short test that helps. "
                + "Right-click the menu bar icon to run it any time.",
            isOn: $supportPrompt.isEnabled
        )
    }

    private var mouseModelsRow: some View {
        settingRow(
            symbol: "computermouse.fill", tint: Color(nsColor: .systemBlue),
            title: "Count my mouse model",
            detail: "The update check also says which mouse model is connected, so I can see which "
                + "mice people use. It's counted with nothing that identifies this Mac.",
            isOn: $updateChecker.sendsMouseModels
        )
    }

    private var usageStatsRow: some View {
        settingRow(
            symbol: "chart.bar.fill", tint: Color(nsColor: .systemPurple),
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
        HStack(spacing: 12) {
            iconChip("trash.fill", tint: Color(nsColor: .systemRed))
            VStack(alignment: .leading, spacing: 2) {
                Text("Delete what's stored").font(.system(size: 13, weight: .medium))
                sectionNote(deletionNote)
            }
            Spacer(minLength: 12)
            Button("Delete My Data…") { confirmingDelete = true }
                .controlSize(.small)
                .disabled(usageStats.deletion == .deleting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            symbol: "arrow.down.circle.fill", tint: Color(nsColor: .systemGreen),
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

    /// The one non-toggle row here: what you're running, when it was last checked, and a way
    /// to ask again. The sidebar's footer has the short form of the same thing.
    private var versionRow: some View {
        HStack(spacing: 12) {
            iconChip("arrow.clockwise", tint: Color(nsColor: .systemGray))
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(updateChecker.currentVersion)")
                    .font(.system(size: 13, weight: .medium))
                sectionNote(checkStatusText)
            }
            Spacer(minLength: 12)
            // An update is available: this page is where the app puts everything about
            // updating, so it should be able to do it rather than send the user to the popover.
            if updateChecker.latestVersion != nil, !updateChecker.isBusy {
                installButton
            }
            checkNowButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    /// Rows on one rounded panel, with an optional small heading above it — the grouped style
    /// System Settings uses. Rows draw their own padding; `rowDivider` goes between them.
    private func settingsGroup<Content: View>(_ heading: String? = nil,
                                              @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let heading {
                Text(heading.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    /// Inset to start under the row's text rather than its icon, as System Settings does.
    private var rowDivider: some View {
        Divider().padding(.leading, 52)
    }

    /// The small coloured square each setting and page carries.
    private func iconChip(_ symbol: String, tint: Color, size: CGFloat = 26) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }

    /// A labelled switch with its icon, its explanation underneath, and an optional slot for a
    /// caption that only appears in some states (unavailable, needs approval, failed).
    private func settingRow<Extra: View>(
        symbol: String, tint: Color, title: String, detail: String, isOn: Binding<Bool>,
        enabled: Bool = true, @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            iconChip(symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                sectionNote(detail)
                extra()
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.razerGreen)
                .controlSize(.small)
                .disabled(!enabled)
                .padding(.top, 3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(enabled ? 1 : 0.55)
    }
}

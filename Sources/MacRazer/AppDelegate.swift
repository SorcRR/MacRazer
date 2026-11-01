// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI
import Combine
import Network
import UserNotifications

/// Menu bar (accessory) app: an NSStatusItem showing battery %, click opens an NSPopover
/// hosting the SwiftUI controls. Mirrors the pattern macOS's own Bluetooth/Battery menus use.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let controller = MouseController()
    private let keyboard = KeyboardController.shared
    private var cancellables = Set<AnyCancellable>()
    private var monitor: HIDMonitor?
    private var bluetoothMonitor: HIDMonitor?
    private let remapper = ButtonRemapper()
    private lazy var remapWindow = RemapWindowController(remapper: remapper, controller: controller)
    private lazy var permissions = PermissionsModel(remapper: remapper, controller: controller)
    private lazy var permissionsWindow = PermissionsWindowController(model: permissions, controller: controller)
    private lazy var deviceTestWindow = DeviceTestWindowController(
        model: DeviceTestModel(controller: controller, permissions: permissions))
    private let updateChecker = UpdateChecker()
    private let launchAtLogin = LaunchAtLogin()
    private let appearance = AppearanceSettings.shared
    /// The solid colour or green tint behind the popover; see `PopoverBackdropView`.
    private let popoverBackdrop = PopoverBackdropView()
    private lazy var aboutWindow = AboutWindowController()
    /// Closing it re-asks the auto-install gate. This window opens unfocused after an
    /// automatic install and can sit unnoticed for days, and while it is open it holds back
    /// any release found in the meantime. Without the re-ask, that release stayed held until
    /// the popover next opened and closed.
    private lazy var updatedWindow = UpdatedWindowController(
        updateChecker: updateChecker, usageStats: usageStats,
        onClosed: { [weak self] in self?.autoInstallIfEnabled() })
    /// Closing it re-asks the auto-install gate, for the same reason as `updatedWindow`.
    private lazy var crashReportWindow = CrashReportWindowController(
        onClosed: { [weak self] in self?.autoInstallIfEnabled() })
    private let usageStats = UsageStats.shared
    /// Closing it re-asks the auto-install gate, for the same reason as `updatedWindow`.
    private lazy var usageStatsWindow = UsageStatsWindowController(
        stats: usageStats, onClosed: { [weak self] in self?.autoInstallIfEnabled() })
    /// Waits for a clear moment to ask about usage stats; see `askAboutUsageStats`.
    private var usageStatsAskTimer: Timer?
    private let supportPrompt = SupportPrompt.shared
    private var supportPromptTimer: Timer?
    /// What the last support tick saw; see `askForDeviceTestIfClear`.
    private var lastUnsupportedMouse: UnsupportedMouse?
    /// Razer mice on USB, listed again only when a Razer device comes or goes, so the support
    /// tick never enumerates devices itself.
    private var razerMiceOnUSB: [HIDDevice.USBMouse] = []
    private var relistRazerMiceWork: DispatchWorkItem?
    /// Closing it re-asks the auto-install gate, for the same reason as `updatedWindow`.
    private lazy var supportPromptWindow = SupportPromptWindowController(
        prompt: supportPrompt,
        onRunTest: { [weak self] in
            guard let self else { return }
            self.present(self.deviceTestWindow)
        },
        onClosed: { [weak self] in self?.autoInstallIfEnabled() })
    private lazy var settingsWindow = SettingsWindowController(
        controller: controller, launchAtLogin: launchAtLogin, updateChecker: updateChecker,
        onAutoInstallChanged: { [weak self] in self?.autoInstallSettingChanged() })
    /// Decides whether an automatic install may start; see `AutoInstallPolicy`.
    private var autoInstallPolicy = AutoInstallPolicy()
    private var updateTimer: Timer?
    private var updateWakeObserver: NSObjectProtocol?
    private var updatePathMonitor: NWPathMonitor?
    /// The last connectivity the monitor reported; nil until its first report.
    private var wasOnline: Bool?
    private var updateBadgeView: NSView?
    /// The app the user was in when the popover opened, so closing it can hand focus back.
    /// See `PopoverFocusReturn` for when it does.
    private var appBeforePopover: NSRunningApplication?
    /// Set whenever one of the app's windows is asked for; cleared when the popover opens.
    /// Catches a window that was already open behind another app being brought back, which
    /// `windowsBeforePopover` alone cannot see.
    private var windowRequested = false
    /// Every window, including system panels, already on screen when the popover opened, so
    /// its close can tell whether it led somewhere new. The colour picker's panel is the case
    /// that needs it: it is not one of the app's windows and does not go through `present`.
    private var windowsBeforePopover: Set<ObjectIdentifier> = []
    /// True while the right-click menu is being tracked.
    private var appMenuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Razer HID devices enumerate as a keyboard/mouse, so macOS gates opening them behind
        // Input Monitoring — without it the app can't read anything. Show the setup window
        // whenever that required permission is missing (and stop the moment it's granted), so a
        // user without it is always walked through it rather than left with a silently-dead app.
        // Button remapping additionally needs Accessibility (optional; surfaced in the same window).
        // A mouse MacRazer controls over Bluetooth needs neither, so it doesn't trigger the window.
        permissions.recheck()
        // Explicit, not a side effect of constructing the model — see the doc comment there.
        launchAtLogin.applyDefaultOnFirstRun()
        LowBatteryNotifier.configureNotifications(delegate: self)
        // A manual button-remap edit (outside applying a profile) means the live config no
        // longer matches whichever profile was last applied — let MouseController know so it
        // can drop the stale "active" highlight.
        remapper.onManualChange = { [weak controller] in controller?.clearActiveProfileIfManuallyChanged() }
        if DeviceTestModel.takeResumeRequest() {
            // Relaunched from the device test to apply Input Monitoring: pick the test back up
            // rather than showing the general setup window it was already past.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.present(self.deviceTestWindow)
            }
        } else if !permissions.allRequiredGranted {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.present(self.permissionsWindow)
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuBarIcon(charging: false)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageHugsTitle = true
        statusItem.button?.title = " …"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        // Receive both clicks so we can branch: left → popover, right → app menu. The menu opens
        // on the right button's press, as macOS's own menu bar items do: the popover closes on
        // that press too, and a menu opened only on the release raced its focus hand-back.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseDown])

        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false // open immediately, no slide animation
        // Light or dark, glass or solid, per Settings › Appearance. Re-applied whenever the
        // setting changes or macOS switches between light and dark, including while the
        // popover is open. The popover's appearance is always set explicitly, never left nil:
        // a nil one would follow the menu bar, which macOS tints from the wallpaper rather
        // than the system's light or dark mode.
        Publishers.CombineLatest3(appearance.$theme, appearance.$glass,
                                  NSApp.publisher(for: \.effectiveAppearance))
            .sink { [weak self] theme, glass, system in
                self?.applyAppearance(theme: theme, glass: glass, systemIsDark: system.isDark)
            }
            .store(in: &cancellables)
        let hosting = NSHostingController(rootView: PopoverView(
            controller: controller, remapper: remapper, updateChecker: updateChecker,
            launchAtLogin: launchAtLogin, appearance: appearance,
            onOpenSettings: { [weak self] in
                // Close first: the popover is transient and would dismiss itself the moment
                // the window takes focus, which looks like the click did two things.
                //
                // Closing here would normally trigger an auto-install, which would relaunch
                // the app out from under the window the user just asked for. That is handled
                // in `popoverDidClose` by looking at whether this window came up — see there.
                guard let self else { return }
                self.popover.performClose(nil)
                self.present(self.settingsWindow)
            },
            onOpenDeviceTest: { [weak self] in
                // Closed first for the same reasons as Settings above.
                guard let self else { return }
                self.popover.performClose(nil)
                self.present(self.deviceTestWindow)
            }))
        hosting.sizingOptions = [.preferredContentSize] // popover auto-fits the SwiftUI content
        popover.contentViewController = hosting

        // Pre-warm: force the SwiftUI hierarchy (incl. the AppKit-backed slider/pickers/colour
        // picker) to build and lay out now, so the first click opens instantly instead of
        // paying that cost on the first show.
        let warm = hosting.view
        warm.frame = NSRect(x: 0, y: 0, width: 300, height: 520)
        warm.layoutSubtreeIfNeeded()
        if let rep = warm.bitmapImageRepForCachingDisplay(in: warm.bounds) {
            warm.cacheDisplay(in: warm.bounds, to: rep)
        }

        // Mirror the controller's status text onto the menu bar title.
        controller.$statusText
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] text in self?.statusItem.button?.title = text }
            .store(in: &cancellables)

        // Swap the mark for its bolt variant while the mouse is on the charger — the same
        // at-a-glance cue macOS gives for its own battery, without needing the popover.
        // Only the two states exist, so the images are cached rather than redrawn per event.
        controller.$charging
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] charging in
                self?.statusItem.button?.image = self?.menuBarIcon(charging: charging)
            }
            .store(in: &cancellables)

        // When disconnected, keep the icon's normal adaptive (template) colour but dim it via
        // opacity — a fixed grey tint disappears against a dark menu bar, whereas a dimmed
        // white/black reads as a clearly-visible lighter grey in both light and dark.
        controller.$connected
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.statusItem.button?.contentTintColor = nil
                self?.statusItem.button?.alphaValue = connected ? 1.0 : 0.6
            }
            .store(in: &cancellables)

        controller.start()

        // Instant plug/unplug detection via IOKit; polling remains the fallback for the
        // wireless-sleep case where the dongle stays present.
        let ctrl = controller
        monitor = HIDMonitor(
            vendorId: Razer.vendorId,
            // Small settle delay on appear so the dongle has re-probed before the first read
            // (avoids a transient 0% right after reconnect).
            onAppear: { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ctrl.forceCheck(immediateOffline: false) }
                MainActor.assumeIsolated {
                    self?.relistRazerMice()
                    self?.keyboard.rescan()
                }
            },
            onRemove: { [weak self] pids in
                MainActor.assumeIsolated {
                    self?.relistRazerMice()
                    self?.keyboard.rescan()
                }
                // Only the connected device's removal is definitive. Matching is vendor-wide,
                // so unplugging a Razer keyboard (or a different-model mouse) fires this too —
                // that must not bypass the offline debounce, or a coincidental wireless
                // timeout at that moment flaps the mouse to "offline" with the disconnect
                // sound. PID granularity can't tell two units of the same model apart, and
                // unknown PIDs (property read failed) are treated as ours — both err on the
                // conservative side (a spurious immediate check self-corrects next poll).
                let mine = ctrl.deviceID.map { pids.isEmpty || pids.contains($0) } ?? false
                ctrl.forceCheck(immediateOffline: mine)
            }
        )

        // A Basilisk on Bluetooth enumerates under Razer's BLE vendor id (0x068E), not the
        // USB id above. An appearance starts recovery but keeps a healthy GATT session;
        // only an observed removal invalidates it before the next probe.
        bluetoothMonitor = HIDMonitor(
            vendorId: BLEProtocol.vendorId,
            onAppear: { pids in
                guard pids.isEmpty || pids.contains(where: RazerDevices.bluetoothPIDs.contains) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    ctrl.beginBluetoothWakeRecovery()
                }
            },
            onRemove: { pids in
                guard pids.contains(where: RazerDevices.bluetoothPIDs.contains) else { return }
                DispatchQueue.main.async { ctrl.beginBluetoothWakeRecovery(discardBluetoothSession: true) }
            }
        )

        // "Also light the keyboard" follows lighting the person sets on the mouse, never the
        // values read from it: the mouse's effect can't be read back, so at launch it is only
        // the default, and following that would repaint the keyboard on every start.
        let ctrl2 = controller
        // Nothing to follow on a one-colour light: the keyboard keeps its own lighting then.
        keyboard.mouseLighting = { [weak ctrl2] in
            ctrl2.flatMap { $0.lightHasFixedColor ? nil : $0 }.map { KeyboardLighting(effect: $0.effect, color: $0.lightingColor, brightness: $0.brightness,
                                         waveSpeed: $0.waveSpeed) }
        }
        keyboard.start()
        let kb = keyboard
        // After `receive(on:)` because @Published emits before the property is set.
        controller.$lightingChanges
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { _ in kb.followMouse() }
            .store(in: &cancellables)
        // Turning it on matches the keyboard to the mouse straight away.
        keyboard.$followsMouse
            .dropFirst()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { _ in kb.followMouse() }
            .store(in: &cancellables)

        remapper.start()
        remapper.observeDpiCycle(controller: controller)

        // Load the connected mouse's own button mappings when the device changes (per-unit key).
        controller.$deviceKey
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] key in self?.remapper.setActiveDevice(key) }
            .store(in: &cancellables)

        // Pause remapping while the mouse is offline (powered off, asleep, dongle pulled) —
        // the tap can't tell devices apart, so an offline mouse's mappings would otherwise
        // keep firing for matching buttons on other pointing devices.
        controller.$connected
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in self?.remapper.remappingPaused = !connected }
            .store(in: &cancellables)
        // A mapped button pressed while paused usually means the mouse just woke. Check now
        // rather than at the next poll, so its mappings come back straight away.
        remapper.onPressWhilePaused = { [weak controller] in controller?.checkIfOffline() }

        // Update check: straight away on launch, then whenever the last answer is more than
        // `UpdateChecker.checkInterval` old. See `startUpdateTriggers()` for what asks.
        updateChecker.$latestVersion
            // A check republishes the same version every day; without this the auto-install
            // gate would be re-evaluated on each one.
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] version in
                self?.setUpdateBadge(visible: version != nil)
                // The published value, not a re-read of the property: `@Published` emits in
                // `willSet`, so the object still holds the old version at this point. The
                // `.receive(on:)` above happens to defer past that today, but the gate must
                // not depend on an operator that looks removable.
                self?.autoInstallIfEnabled(available: version)
            }
            .store(in: &cancellables)
        // Before the check, and synchronously: this compares the running version against the
        // last one recorded and then records the new one, so it has to happen exactly once per
        // launch and before anything else can write that key.
        updateChecker.loadInstalledVersionState()
        // First launch on a new version: say the update worked, with what it brought. Only
        // takes focus when the user asked for the install; an automatic one finishes while
        // they are doing something else.
        if updateChecker.justUpdatedTo != nil {
            updatedWindow.show(activating: !updateChecker.autoInstallEnabled)
        }
        startUsageStats()
        startSupportPrompt()
        // A crash since the last launch, offered once. Looked for again a little later
        // because the crash most likely to be waiting is the one in the instance that just
        // handed over to this one, during a relaunch: macOS writes its report a few seconds
        // after this instance has already started.
        crashReportWindow.offerNewCrash()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.crashReportWindow.offerNewCrash()
        }
        // Unthrottled: a launch is rare, and it is when someone who just installed or reopened
        // the app most expects it to know about the latest release.
        updateChecker.connectedMice = { [weak self] in self?.usageStats.connectedMice ?? [] }
        Task { await updateChecker.checkForUpdatesNow() }
        startUpdateTriggers()
    }

    /// Everything that asks "is a check due?" after launch. Each only asks: the throttle in
    /// `UpdateChecker` decides, and a check already running is shared rather than repeated.
    private func startUpdateTriggers() {
        // A tick much shorter than the interval, not a timer set to it. A timer of exactly
        // three hours fires a moment before the throttle opens, because the check it follows
        // finished a little after it started, and so waited a whole extra period each time.
        // A timer also stops counting while the Mac sleeps.
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { await self?.updateChecker.checkForUpdatesIfDue() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer

        // A Mac that slept past the interval asks the moment it wakes, rather than whenever
        // the tick above next comes round.
        updateWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.updateChecker.checkForUpdatesIfDue() }
            }
        }

        // The network is often not back yet at wake, and a failed check is not recorded, so
        // it stays due. Ask again as soon as a connection appears. The first report is the
        // state at start, not a change, and is only remembered.
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.wasOnline = online }
                guard self.wasOnline == false, online else { return }
                Task { await self.updateChecker.checkForUpdatesIfDue() }
            }
        }
        pathMonitor.start(queue: .main)
        updatePathMonitor = pathMonitor
    }

    /// Small red dot over the status-item icon when an update is available. A subview rather
    /// than baking it into the icon image — the icon is a template image that macOS recolors
    /// automatically for light/dark menu bars, and a baked-in dot would lose its red color to
    /// that same recoloring.
    private func setUpdateBadge(visible: Bool) {
        guard let button = statusItem.button else { return }
        guard visible else {
            updateBadgeView?.removeFromSuperview()
            updateBadgeView = nil
            return
        }
        guard updateBadgeView == nil else { return }
        let dotSize: CGFloat = 6
        let dot = NSView(frame: NSRect(
            x: button.bounds.width - dotSize, y: button.bounds.height - dotSize,
            width: dotSize, height: dotSize))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = dotSize / 2
        dot.autoresizingMask = [.minXMargin, .minYMargin]
        button.addSubview(dot)
        updateBadgeView = dot
    }

    // MARK: - Click handling

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if StatusItemClick.opensMenu(eventType: event?.type,
                                     pressedButtons: NSEvent.pressedMouseButtons,
                                     control: event?.modifierFlags.contains(.control) == true
                                         || NSEvent.modifierFlags.contains(.control)) {
            showAppMenu()
        } else {
            togglePopover()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Remember where focus came from, so closing can hand it back. Not overwritten when
            // MacRazer is already frontmost: "Open Controls" from the right-click menu reopens
            // the popover mid-session, and the app to go back to is still the earlier one.
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != NSRunningApplication.current.processIdentifier {
                appBeforePopover = front
            }
            windowRequested = false
            windowsBeforePopover = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            // Show first (instant), then kick off the refresh so the open never waits on IO.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // The frame view the backdrop lives in only exists once the popover is shown.
            installPopoverBackdrop()
            // Activate, not just make key. This app has no Dock icon, so clicking the menu bar
            // item does not make it the active application, and a control in an inactive app's
            // window does not respond to the first click the way it looks like it should. Every
            // other window here already does this; the popover was the one that did not.
            // The cost is that the app keeps focus once the popover closes, which
            // `returnFocusAfterPopover` gives back.
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            controller.refreshAll()
            // Someone looking at the popover is the person an update card is for. Throttled,
            // so opening it often costs nothing.
            Task { await updateChecker.checkForUpdatesIfDue() }
        }
    }

    // MARK: - App menu (right-click)

    private func showAppMenu() {
        // Held for the whole of the tracking below, so a popover closing on the way here does
        // not hand focus to another app, which would dismiss this menu. See
        // `returnFocusAfterPopover`.
        appMenuOpen = true
        if popover.isShown { popover.performClose(nil) }

        let menu = NSMenu()

        // First, where macOS puts About in an app menu — above the device header, which is a
        // title for the items below it rather than an item itself.
        let about = NSMenuItem(title: "About MacRazer", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        let status = NSMenuItem(title: appMenuStatusTitle(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Controls", action: #selector(togglePopover), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let configure = NSMenuItem(title: "Configure Buttons…", action: #selector(openRemap), keyEquivalent: "")
        configure.target = self
        configure.isEnabled = controller.connected // remapping is for a connected mouse
        menu.addItem(configure)

        // Every connected mouse gets it: on an unverified one it gathers what's needed to
        // support it, on a verified one it confirms it still works. Enabled whenever a Razer
        // device is plugged in rather than only once connected, so someone missing Input
        // Monitoring can still reach the screen that asks for it.
        let verified = controller.connected && controller.deviceSupported
        let test = NSMenuItem(title: verified ? "Test This Mouse…" : "Help Support This Mouse…",
                              action: #selector(openDeviceTest), keyEquivalent: "")
        test.target = self
        test.isEnabled = controller.connected || DeviceTestModel.razerMousePresent
        menu.addItem(test)

        let setup = NSMenuItem(title: "Setup & Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // The background check runs every few hours; this is the way to ask for one now, and it
        // also un-dismisses a version the user waved away earlier.
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        menu.addItem(.separator())

        let tip = NSMenuItem(title: "Leave a Tip…", action: #selector(openTip), keyEquivalent: "")
        tip.target = self
        tip.image = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)
        menu.addItem(tip)

        let quit = NSMenuItem(title: "Quit MacRazer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Pop the menu just below the status item.
        if let button = statusItem.button {
            let origin = NSPoint(x: 0, y: button.bounds.height + 5)
            menu.popUp(positioning: nil, at: origin, in: button)
        }
        appMenuOpen = false
        // Tracking is over, so the choice is made: reopening the popover, opening a window, or
        // nothing. Deferred a turn for the same reason as `popoverDidClose`: the answer is read
        // after the chosen item has acted, rather than raced against it.
        DispatchQueue.main.async { [weak self] in self?.returnFocusAfterPopover() }
    }

    private func appMenuStatusTitle() -> String {
        let name = controller.deviceName ?? "No mouse connected"
        guard controller.connected, let pct = controller.batteryPercent else {
            return name
        }
        return "\(name) · \(pct)%" + (controller.charging ? " (charging)" : "")
    }

    @objc private func refreshNow() { controller.refreshAll() }
    @objc private func checkForUpdates() {
        Task {
            await updateChecker.checkForUpdatesNow(userRequested: true)
            // Open the popover either way: with an update it shows the card, without one it
            // shows the version in the footer — both answer "am I up to date?".
            if !popover.isShown { togglePopover() }
        }
    }
    @objc private func openRemap() { present(remapWindow) }
    @objc private func openSettings() { present(settingsWindow) }
    @objc private func openAbout() { present(aboutWindow) }

    /// Every way the app opens one of its windows goes through here. Marks the request, so a
    /// popover closing on the way to the window keeps focus instead of handing it back.
    private func present(_ window: AppWindowPresenter) {
        windowRequested = true
        window.show()
    }

    /// Whether the user is currently looking at one of the app's windows.
    ///
    /// Touching the lazy controllers here builds the controllers but not their windows — each
    /// initializer only stores a few references, and the `NSWindow` is still created on the
    /// first `show()`. So the laziness that matters is intact.
    private var isShowingAWindow: Bool {
        // The device test in particular: an install ends in a relaunch, and that must never
        // happen while a step has a test value on someone's mouse.
        let windows: [AppWindowPresenter] = [remapWindow, permissionsWindow, aboutWindow, settingsWindow,
                                             updatedWindow, deviceTestWindow, crashReportWindow,
                                             usageStatsWindow, supportPromptWindow]
        return windows.contains { $0.isVisible }
    }

    // MARK: - Usage stats

    /// Feeds the connected mouse to `UsageStats`, sends whatever is due, and asks once if
    /// nobody has been asked yet. Nothing goes anywhere without a yes; see `UsageStats`.
    private func startUsageStats() {
        // Debounced: the controller publishes a new mouse's fields one at a time, and the
        // ping should see them all.
        Publishers.CombineLatest4(controller.$connected, controller.$deviceID,
                                  controller.$deviceName, controller.$deviceIsBluetooth)
            .combineLatest(controller.$deviceSupported)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] device, supported in
                let (connected, pid, name, bluetooth) = device
                let mice = connected ? pid.map {
                    [UsageStatsPolicy.mouse(pid: $0, productName: name, isBluetooth: bluetooth, supported: supported)]
                } ?? [] : []
                self?.usageStats.setConnectedMice(mice)
            }
            .store(in: &cancellables)
        // A mouse usually connects within a few seconds of launch and goes with the first
        // ping. Without one, the ping goes anyway after this, and the mouse follows later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            Task { await self.usageStats.sendIfDue() }
        }
        // Someone who just updated is asked in the Updated window instead. A `swift run`
        // build has no version and a build without the Worker has nowhere to send, so
        // neither of them asks.
        if usageStats.isAvailable, usageStats.consent == .undecided, updateChecker.justUpdatedTo == nil,
           AppInfo.version != nil {
            askAboutUsageStats()
        }
    }

    /// The consent window, once nothing else is in the way: not over the setup window, the
    /// device test, a crash report or the popover. A new install opens onto the setup window,
    /// and stats are the last thing anyone wants to be asked before the app even works.
    private func askAboutUsageStats() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.askAboutUsageStatsIfClear() }
        }
        // Not straight away even when clear: the menu bar item has only just appeared.
        timer.fireDate = Date().addingTimeInterval(5)
        RunLoop.main.add(timer, forMode: .common)
        usageStatsAskTimer = timer
    }

    private func askAboutUsageStatsIfClear() {
        guard usageStats.consent == .undecided else { return stopAskingAboutUsageStats() }
        guard !isShowingAWindow, !popover.isShown, !appMenuOpen else { return }
        stopAskingAboutUsageStats()
        usageStatsWindow.show(activating: false)
    }

    private func stopAskingAboutUsageStats() {
        usageStatsAskTimer?.invalidate()
        usageStatsAskTimer = nil
    }

    // MARK: - Support prompt

    /// Asks someone with an unverified mouse to run the device test, at a clear moment; see
    /// `SupportPromptPolicy` for how often. Also notes when a report goes out, from wherever
    /// the test was opened, so nothing asks about that model again.
    private func startSupportPrompt() {
        supportPrompt.trackReports(from: deviceTestWindow.model).store(in: &cancellables)
        razerMiceOnUSB = listRazerMiceIfNeeded()
        // The list is kept empty while the setting is off, so turning it on lists what is
        // already plugged in instead of waiting for the next plug event.
        supportPrompt.$isEnabled.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.relistRazerMice() }
            .store(in: &cancellables)
        // A timer for the moment, not the mouse: "clear" (no window, popover or menu) changes
        // without any event this could hang off. Each tick is a few property reads; the
        // device list it needs is kept current by the plug monitor instead.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.askForDeviceTestIfClear() }
        }
        // Not straight away: the mouse is still being opened and the setup window may be next.
        timer.fireDate = Date().addingTimeInterval(10)
        RunLoop.main.add(timer, forMode: .common)
        supportPromptTimer = timer
    }

    /// After a plug event settles: a dongle's interfaces arrive one by one, and a removed
    /// device can still be listed for a moment while it is torn down. Every interface fires
    /// its own event, so a burst is folded into one listing.
    private func relistRazerMice() {
        relistRazerMiceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.razerMiceOnUSB = self.listRazerMiceIfNeeded()
        }
        relistRazerMiceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The list is read only for a mouse without Input Monitoring, and only while the prompt is
    /// on. Otherwise, the usual case, a dongle waking from sleep isn't worth an enumeration.
    private func listRazerMiceIfNeeded() -> [HIDDevice.USBMouse] {
        guard supportPrompt.isEnabled, !DeviceTestModel.inputMonitoringGranted else { return [] }
        return HIDDevice.razerMice()
    }

    private func askForDeviceTestIfClear() {
        guard supportPrompt.isEnabled else { return }
        // The same mouse on two ticks in a row. The controller publishes a new mouse's fields
        // one at a time, and a tick between them could pair its id with the last one's name
        // or link, and spend the ask on that. Read on every tick, clear or not, so the last
        // reading is never one from before a window was open.
        let mouse = unsupportedMouse
        defer { lastUnsupportedMouse = mouse }
        guard let mouse, mouse == lastUnsupportedMouse,
              !isShowingAWindow, !popover.isShown, !appMenuOpen,
              supportPrompt.shouldAsk(pid: mouse.pid) else { return }
        supportPromptWindow.show(for: mouse)
    }

    /// The connected mouse if a report would still help, else one plugged in that the app can't
    /// open. On Bluetooth only a mouse fully supported there, whose other links need a test: the
    /// prompt then points at those, and the full test needs the cable or the dongle anyway.
    private var unsupportedMouse: UnsupportedMouse? {
        if controller.connected, let pid = controller.deviceID {
            guard RazerDevices.needsReport(pid: pid),
                  !controller.deviceIsBluetooth || RazerDevices.support(pid: pid) == .full else { return nil }
            return UnsupportedMouse(pid: pid, name: controller.deviceName ?? "Razer Mouse", canControl: true)
        }
        return SupportPrompt.mouseWithoutAccess(among: razerMiceOnUSB,
                                                accessGranted: DeviceTestModel.inputMonitoringGranted)
    }

    /// Turning the setting on with an update already found is the one moment a user is
    /// watching for it to act, and neither of the other triggers fires then: `latestVersion`
    /// hasn't changed (so the deduplicated sink stays quiet) and the popover was never open.
    private func autoInstallSettingChanged() { autoInstallIfEnabled() }
    @objc private func openPermissions() { present(permissionsWindow) }
    @objc private func openDeviceTest() { present(deviceTestWindow) }
    @objc private func openTip() { NSWorkspace.shared.open(ProjectLinks.tip) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - Appearance

    private func applyAppearance(theme: PopoverTheme, glass: Bool, systemIsDark: Bool) {
        let look = PopoverLook.resolve(theme: theme, glass: glass, systemIsDark: systemIsDark)
        popover.appearance = NSAppearance(named: look.appearanceName)
        popoverBackdrop.fill = look.backdropColor
        appearance.applyToWindows(look)
    }

    /// Puts the backdrop into the popover's frame view, just under the content: above the
    /// native material, so a solid colour hides it, and filling the arrow too. NSPopover
    /// keeps its frame view between shows, so this only does work the first time.
    private func installPopoverBackdrop() {
        guard let content = popover.contentViewController?.view,
              let frameView = content.superview,
              popoverBackdrop.superview !== frameView else { return }
        popoverBackdrop.frame = frameView.bounds
        popoverBackdrop.autoresizingMask = [.width, .height]
        frameView.addSubview(popoverBackdrop, positioned: .below, relativeTo: content)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        controller.setPopoverVisible(true)
        // Re-reads the keyboard's brightness: its own keys change it behind the app's back.
        keyboard.rescan()
    }
    func popoverDidClose(_ notification: Notification) {
        controller.setPopoverVisible(false)
        // An update found while the popover was open was deliberately left alone; now that
        // it's closed, the restart is no longer disruptive — unless the close was on the way
        // to opening Settings, in which case relaunching would take that window with it.
        //
        // Deferred a turn so the answer is a fact rather than a race. Two earlier attempts
        // used a flag set around `performClose`, which only worked if AppKit delivered this
        // callback at a particular moment it never promised to. By the next runloop turn the
        // settings window has either come up or it hasn't, and `autoInstallIfEnabled` reads
        // that directly.
        DispatchQueue.main.async { [weak self] in
            self?.autoInstallIfEnabled()
            // Same reasoning decides focus: by now the window the close was for has come up,
            // or it has not.
            self?.returnFocusAfterPopover()
        }
    }

    // MARK: - Popover focus

    /// Hands keyboard focus back to the app the user was in, when the popover session is over
    /// and nothing says to stay. Called a turn after each way that session can end: the popover
    /// closing, and the right-click menu finishing. See `PopoverFocusReturn` for the rules.
    private func returnFocusAfterPopover() {
        let previous = appBeforePopover.flatMap { $0.isTerminated ? nil : $0 }
        let popoverWindow = popover.contentViewController?.view.window
        let somethingNewOnScreen = NSApp.windows.contains {
            $0.isVisible && $0 !== popoverWindow && !windowsBeforePopover.contains(ObjectIdentifier($0))
        }
        let verdict = PopoverFocusReturn.verdict(.init(
            appMenuOpen: appMenuOpen,
            menuClickHeld: PopoverFocusReturn.menuClickHeld(pressedButtons: NSEvent.pressedMouseButtons,
                                                            control: NSEvent.modifierFlags.contains(.control)),
            popoverShown: popover.isShown,
            windowOpened: windowRequested || somethingNewOnScreen,
            appIsActive: NSApp.isActive,
            hasPreviousApp: previous != nil))
        switch verdict {
        case .wait where !appMenuOpen && !popover.isShown:
            // Only a held click is keeping it: a menu may open when it lets go, or nothing may,
            // when it's released off the icon. Look again shortly rather than leave focus here.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.returnFocusAfterPopover() }
        case .wait:
            return
        case .stay:
            appBeforePopover = nil
        case .returnFocus:
            appBeforePopover = nil
            guard let previous else { return }
            // Cooperative activation, the way macOS 14 expects it: the active app yields, and
            // the target takes activation from it.
            NSApp.yieldActivation(to: previous)
            _ = previous.activate(from: .current, options: [])
        }
    }

    // MARK: - Automatic updates

    /// Silent install, when the user has switched it on. Deliberately never while the popover
    /// is open: the install ends in a relaunch, and pulling the window out from under someone
    /// mid-click is worse than waiting for the next opportunity. A failure falls through to
    /// the ordinary update card, so a broken auto-install can't quietly strand anyone on an
    /// old version.
    private func autoInstallIfEnabled(available: String? = nil) {
        let conditions = AutoInstallPolicy.Conditions(
            availableVersion: available ?? updateChecker.latestVersion,
            enabled: updateChecker.autoInstallEnabled,
            canInstallInPlace: updateChecker.canInstallInPlace,
            busy: updateChecker.isBusy,
            // No surface may be yanked away mid-use: the popover for the reason above, and
            // any window the app has open, because an install ends in a relaunch. Asked of
            // every window rather than a named one — enumerating them here is what left the
            // About window exposed the moment it was added.
            popoverVisible: popover.isShown || isShowingAWindow)
        // The policy returns the version it approved rather than a Bool: it records the
        // attempt as part of deciding, so a caller that had to re-unwrap afterwards could
        // silently drop a version already marked as spent.
        guard let version = autoInstallPolicy.versionToInstall(conditions) else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.updateChecker.downloadAndInstall()
            // A dropped connection must not cost the user automatic updates until they next
            // relaunch — this app starts at login and can run for weeks.
            if let error = self.updateChecker.lastInstallError,
               !self.autoInstallPolicy.isPermanent(error) {
                self.autoInstallPolicy.retryLater(version)
            }
        }
    }

    // MARK: - Foreground

    /// Re-check permissions when the app returns to the foreground — e.g. the user just toggled
    /// a grant in System Settings and switched back, so the setup window reflects it live.
    func applicationDidBecomeActive(_ notification: Notification) {
        permissions.recheck()
        // Same reason as the permission recheck: the user may have just flipped the
        // Notifications switch — or MacRazer's Login Items entry — in System Settings and
        // come back.
        controller.refreshNotificationAuthorization()
        launchAtLogin.refresh()
    }

    /// Another app took focus. A hand-back still pending from the popover must not take it
    /// back: whatever the user just moved to wins.
    func applicationDidResignActive(_ notification: Notification) {
        appBeforePopover = nil
    }

    /// A device test step may have the mouse dark, red, or at a test DPI, and puts it back when
    /// it finishes, a few seconds at most. Quitting first would leave it that way: the history
    /// flush below only waits two seconds for the device queue, less than the lighting step.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = deviceTestWindow.model
        guard model.running else { return .terminateNow }
        model.whenIdle { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.invalidate()
        updateTimer?.invalidate()
        updatePathMonitor?.cancel()
        controller.flushHistoryToDisk()
    }

    // MARK: - Menu bar mark

    /// The status-item marks, drawn once each. Neither has to be redrawn for the menu bar's
    /// appearance: the idle one is a template image macOS recolours itself, and the charging
    /// one resolves its colours whenever it is drawn (see `MenuBarIcon.chargingBody`).
    ///
    /// So nothing here watches `effectiveAppearance`, on purpose. Setting the image makes
    /// AppKit report that property as changed whether or not it did, and a watcher that sets
    /// the image in response never stops (issue #25).
    private static let idleIcon = MenuBarIcon.mouse(pointSize: 21, razerCutout: false)
    private static let chargingIcon = MenuBarIcon.mouse(pointSize: 21, razerCutout: false, charging: true)

    private func menuBarIcon(charging: Bool) -> NSImage {
        charging ? Self.chargingIcon : Self.idleIcon
    }

    // MARK: - Notifications

    /// Present the low-battery banner even while MacRazer is frontmost (the default is to
    /// suppress it, which would silently swallow the alert).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Input Monitoring permission

    static func openInputMonitoringSettings() { SystemSettingsPanes.openInputMonitoring() }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI
import Combine

/// Menu bar (accessory) app: an NSStatusItem showing battery %, click opens an NSPopover
/// hosting the SwiftUI controls. Mirrors the pattern macOS's own Bluetooth/Battery menus use.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let controller = MouseController()
    private var cancellables = Set<AnyCancellable>()
    private var monitor: HIDMonitor?
    private let remapper = ButtonRemapper()
    private lazy var remapWindow = RemapWindowController(remapper: remapper)
    private lazy var permissions = PermissionsModel(remapper: remapper, controller: controller)
    private lazy var permissionsWindow = PermissionsWindowController(model: permissions, controller: controller)
    private let updateChecker = UpdateChecker()
    private var updateTimer: Timer?
    private var updateBadgeView: NSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Razer HID devices enumerate as a keyboard/mouse, so macOS gates opening them behind
        // Input Monitoring — without it the app can't read anything. Show the setup window
        // whenever that required permission is missing (and stop the moment it's granted), so a
        // user without it is always walked through it rather than left with a silently-dead app.
        // Button remapping additionally needs Accessibility (optional; surfaced in the same window).
        permissions.recheck()
        // A manual button-remap edit (outside applying a profile) means the live config no
        // longer matches whichever profile was last applied — let MouseController know so it
        // can drop the stale "active" highlight.
        remapper.onManualChange = { [weak controller] in controller?.clearActiveProfileIfManuallyChanged() }
        if !permissions.inputMonitoring {
            DispatchQueue.main.async { [weak self] in self?.permissionsWindow.show() }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = MenuBarIcon.mouse(pointSize: 21, razerCutout: false)
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageHugsTitle = true
        statusItem.button?.title = " …"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        // Receive both clicks so we can branch: left → popover, right → app menu.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false // open immediately, no slide animation
        // Force a dark popover regardless of system appearance — the Razer-green accent and
        // logo have poor contrast on the light-mode grey material; dark is also the gaming
        // aesthetic and makes the green pop.
        popover.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingController(rootView: PopoverView(controller: controller, remapper: remapper, updateChecker: updateChecker))
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
            .receive(on: RunLoop.main)
            .sink { [weak self] text in self?.statusItem.button?.title = text }
            .store(in: &cancellables)

        // When disconnected, keep the icon's normal adaptive (template) colour but dim it via
        // opacity — a fixed grey tint disappears against a dark menu bar, whereas a dimmed
        // white/black reads as a clearly-visible lighter grey in both light and dark.
        controller.$connected
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
            onAppear: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ctrl.forceCheck(immediateOffline: false) } },
            onRemove: { ctrl.forceCheck(immediateOffline: true) }
        )

        remapper.start()

        // Load the connected mouse's own button mappings when the device changes (per-unit key).
        controller.$deviceKey
            .receive(on: RunLoop.main)
            .sink { [weak self] key in self?.remapper.setActiveDevice(key) }
            .store(in: &cancellables)

        // Update check: once now (throttled internally to once/24h), then a daily timer so a
        // long-running session still notices new releases without a relaunch.
        updateChecker.$latestVersion
            .receive(on: RunLoop.main)
            .sink { [weak self] version in self?.setUpdateBadge(visible: version != nil) }
            .store(in: &cancellables)
        Task { await updateChecker.checkForUpdatesIfDue() }
        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { await self?.updateChecker.checkForUpdatesIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
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
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRightClick {
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
            // Show first (instant), then kick off the refresh so the open never waits on IO.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            controller.refreshAll()
        }
    }

    // MARK: - App menu (right-click)

    private func showAppMenu() {
        if popover.isShown { popover.performClose(nil) }

        let menu = NSMenu()

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

        let setup = NSMenuItem(title: "Setup & Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacRazer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Pop the menu just below the status item.
        if let button = statusItem.button {
            let origin = NSPoint(x: 0, y: button.bounds.height + 5)
            menu.popUp(positioning: nil, at: origin, in: button)
        }
    }

    private func appMenuStatusTitle() -> String {
        let name = controller.deviceName ?? "No mouse connected"
        guard controller.connected, let pct = controller.batteryPercent else {
            return name
        }
        return "\(name) — \(pct)%" + (controller.charging ? " (charging)" : "")
    }

    @objc private func refreshNow() { controller.refreshAll() }
    @objc private func openRemap() { remapWindow.show() }
    @objc private func openPermissions() { permissionsWindow.show() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) { controller.setPopoverVisible(true) }
    func popoverDidClose(_ notification: Notification) { controller.setPopoverVisible(false) }

    // MARK: - Foreground

    /// Re-check permissions when the app returns to the foreground — e.g. the user just toggled
    /// a grant in System Settings and switched back, so the setup window reflects it live.
    func applicationDidBecomeActive(_ notification: Notification) {
        permissions.recheck()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.invalidate()
        updateTimer?.invalidate()
    }

    // MARK: - Input Monitoring permission

    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

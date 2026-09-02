// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Hosts the app's settings in a normal window. Reachable from the menu bar's right-click
/// menu (⌘,) and from the gear in the popover footer.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let controller: MouseController
    private let launchAtLogin: LaunchAtLogin
    private let updateChecker: UpdateChecker

    /// Called when the "install automatically" switch is flipped — see `SettingsView`.
    private let onAutoInstallChanged: () -> Void

    init(controller: MouseController, launchAtLogin: LaunchAtLogin, updateChecker: UpdateChecker,
         onAutoInstallChanged: @escaping () -> Void) {
        self.controller = controller
        self.launchAtLogin = launchAtLogin
        self.updateChecker = updateChecker
        self.onAutoInstallChanged = onAutoInstallChanged
    }

    func show() {
        if window == nil {
            let root = SettingsView(controller: controller, launchAtLogin: launchAtLogin,
                                    updateChecker: updateChecker,
                                    onDone: { [weak self] in self?.window?.close() },
                                    onAutoInstallChanged: onAutoInstallChanged)
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "MacRazer Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Match the popover's forced-dark look so the green accent reads correctly.
            w.appearance = NSAppearance(named: .darkAqua)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Opening is the moment the login-item switch has to be right: the user may have
        // changed it in System Settings since this window was last built.
        launchAtLogin.refresh()
    }
}

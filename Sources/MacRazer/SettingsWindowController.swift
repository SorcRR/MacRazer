// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Hosts the app's settings in a normal window. Reachable from the menu bar's right-click
/// menu (⌘,) and from the gear in the popover footer.
@MainActor
final class SettingsWindowController: AppWindowPresenter {
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

    /// Whether the window is actually on screen. Reading this builds the controller if it
    /// hasn't been already, which costs three stored references — the `NSWindow` itself is
    /// still only created by `show()`.
    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let root = SettingsView(controller: controller, launchAtLogin: launchAtLogin,
                                    updateChecker: updateChecker,
                                    onDone: { [weak self] in self?.window?.close() },
                                    onAutoInstallChanged: onAutoInstallChanged)
            let hosting = NSHostingController(rootView: root)
            // No automatic sizing: the view is a fixed size, and the size the hosting
            // controller asks for counts the title bar strip the view draws under, which
            // would leave a 28pt empty band at the bottom.
            hosting.sizingOptions = []
            let w = NSWindow(contentViewController: hosting)
            w.title = "MacRazer Settings"
            // The sidebar runs up under the traffic lights, as in System Settings, so the
            // title bar draws no title of its own. The title stays set for the Window menu
            // and VoiceOver.
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titleVisibility = .hidden
            w.setContentSize(SettingsView.size)
            // The content now covers the title bar strip, and a hosting view doesn't pass a
            // drag there on to the window. Controls still take their own clicks.
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            // Themed like the popover per Settings › Appearance, kept up to date when it changes.
            AppearanceSettings.shared.track(w)
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

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Hosts About MacRazer in a normal window, reached from the menu bar's right-click menu.
@MainActor
final class AboutWindowController: AppWindowPresenter {
    private var window: NSWindow?
    /// Held so the root view can be rebuilt on each open. Without it the window is created
    /// once and keeps whatever it was built with — and it is built with the release notes,
    /// which arrive from a background check that may not have returned yet. Opening About in
    /// the first seconds after launch would otherwise hide the "What's new" row for the rest
    /// of the session.
    private var hosting: NSHostingController<AboutView>?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        // Rebuilt on every open, not once: `notes` comes from a background check that may not
        // have returned when the window was first created.
        let root = AboutView(onDone: { [weak self] in self?.window?.close() },
                             notes: UpdateChecker.notesForRunningVersion())
        if let hosting {
            hosting.rootView = root
        } else {
            let controller = NSHostingController(rootView: root)
            controller.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: controller)
            w.title = "About MacRazer"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Match the popover and the other windows: the green accent needs a dark ground.
            w.appearance = NSAppearance(named: .darkAqua)
            w.center()
            hosting = controller
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

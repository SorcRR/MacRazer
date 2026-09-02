// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Hosts About MacRazer in a normal window, reached from the menu bar's right-click menu.
@MainActor
final class AboutWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let root = AboutView(onDone: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "About MacRazer"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Match the popover and the other windows: the green accent needs a dark ground.
            w.appearance = NSAppearance(named: .darkAqua)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Hosts the button-remapping UI in a normal window (the popover is for quick controls only).
/// An accessory app can show a window; we just activate first so it comes to the front.
@MainActor
final class RemapWindowController {
    private var window: NSWindow?
    private let remapper: ButtonRemapper

    init(remapper: ButtonRemapper) { self.remapper = remapper }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: RemapView(remapper: remapper))
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "Configure Buttons"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Opening is a natural moment to (re)check / prompt for Accessibility.
        remapper.refreshAccessibility(prompt: true)
    }
}

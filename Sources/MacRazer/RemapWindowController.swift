// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Hosts the button-remapping UI in a normal window (the popover is for quick controls only).
/// An accessory app can show a window; we just activate first so it comes to the front.
@MainActor
final class RemapWindowController: AppWindowPresenter {
    private var window: NSWindow?
    private let remapper: ButtonRemapper
    private let controller: MouseController

    init(remapper: ButtonRemapper, controller: MouseController) {
        self.remapper = remapper
        self.controller = controller
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: RemapView(remapper: remapper, controller: controller))
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
        // Recheck silently; only the explicit Request button should raise a native prompt.
        remapper.refreshAccessibility(prompt: false)
    }
}

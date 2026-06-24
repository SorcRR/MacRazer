// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Hosts the first-run setup / permissions screen in a normal window. Shown automatically on the
/// very first launch and reachable any time from the menu bar's "Setup & Permissions…".
@MainActor
final class PermissionsWindowController {
    private var window: NSWindow?
    private let model: PermissionsModel
    private let controller: MouseController

    init(model: PermissionsModel, controller: MouseController) {
        self.model = model
        self.controller = controller
    }

    func show() {
        if window == nil {
            let root = PermissionsView(model: model, controller: controller,
                                       onDone: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "MacRazer Setup"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Match the popover's forced-dark look so the green accent reads correctly.
            w.appearance = NSAppearance(named: .darkAqua)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.recheck()
    }
}

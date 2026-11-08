// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// The lighting test for a keyboard or mousepad, opened from its card in the popover.
@MainActor
final class AccessoryTestWindowController: NSObject, AppWindowPresenter, NSWindowDelegate {
    private var window: NSWindow?
    let model: AccessoryTestModel

    init(model: AccessoryTestModel) { self.model = model }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Opens the test on `accessory`.
    func show(_ accessory: AccessoryController) {
        model.load(accessory)
        show()
    }

    func show() {
        if window == nil {
            let root = AccessoryTestView(model: model, onClose: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            AppearanceSettings.shared.track(w)
            w.delegate = self
            w.center()
            window = w
        }
        window?.title = "Test \(model.accessory?.info.kind.label ?? "Keyboard") Lighting"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing starts the next test from the top. A test still running finishes on the
    /// accessory's queue and puts everything back by itself.
    func windowWillClose(_ notification: Notification) { model.reset() }
}

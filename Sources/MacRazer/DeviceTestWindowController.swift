// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

@MainActor
final class DeviceTestWindowController: NSObject, AppWindowPresenter, NSWindowDelegate {
    private var window: NSWindow?
    let model: DeviceTestModel

    init(model: DeviceTestModel) { self.model = model }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let root = DeviceTestView(model: model, onClose: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Match the popover's forced-dark look, like the app's other windows.
            w.appearance = NSAppearance(named: .darkAqua)
            w.delegate = self
            w.center()
            window = w
        }
        window?.title = model.isKnownSupported ? "Test This Mouse" : "Help Support This Mouse"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    /// Back in front after a trip to System Settings: the grant may have just happened.
    func windowDidBecomeKey(_ notification: Notification) { model.recheckAccess() }

    /// Closing at any point hands the mouse back. Every step has already put back what it
    /// changed; this resumes the app's own reads and starts the next test from the top.
    func windowWillClose(_ notification: Notification) { model.reset() }
}

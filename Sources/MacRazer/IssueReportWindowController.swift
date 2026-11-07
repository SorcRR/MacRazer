// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Hosts `IssueReportView`, opened from the menu bar item's menu.
@MainActor
final class IssueReportWindowController: NSObject, AppWindowPresenter, NSWindowDelegate {
    private var window: NSWindow?
    let model: IssueReportModel

    init(model: IssueReportModel) { self.model = model }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let root = IssueReportView(model: model, onClose: { [weak self] in self?.window?.close() })
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "Report an Issue"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Themed like the popover per Settings › Appearance, kept up to date when it changes.
            AppearanceSettings.shared.track(w)
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.windowClosed() }
}

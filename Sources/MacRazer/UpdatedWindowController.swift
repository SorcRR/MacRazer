// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Hosts `UpdatedView` in a window of its own, opened by the app on the first launch after an
/// update rather than by anything the user clicks.
///
/// Closing it, by Done or by the close button, dismisses the announcement. The popover's
/// "Updated to …" card would otherwise repeat news the user has just read.
@MainActor
final class UpdatedWindowController: NSObject, AppWindowPresenter, NSWindowDelegate {
    private let updateChecker: UpdateChecker
    private var window: NSWindow?

    init(updateChecker: UpdateChecker) {
        self.updateChecker = updateChecker
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() { show(activating: true) }

    /// - Parameter activating: whether to take focus. False after an automatic install, which
    ///   happened while the user was busy elsewhere and should not grab their keyboard when
    ///   it lands. The window still comes to the front, where it will be seen.
    func show(activating: Bool) {
        if window == nil {
            let controller = NSHostingController(rootView: UpdatedView(
                updateChecker: updateChecker,
                onDone: { [weak self] in self?.window?.close() }))
            controller.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: controller)
            w.title = "MacRazer Updated"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Match the other windows: the green accent needs a dark ground.
            w.appearance = NSAppearance(named: .darkAqua)
            w.delegate = self
            w.center()
            window = w
        }
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        updateChecker.dismissAnnouncement()
    }
}

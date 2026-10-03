// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Hosts `CrashReportView`, opened by the app after it finds a crash rather than by a click.
///
/// It doesn't take focus. It usually appears at login or right after an update, while the
/// person is doing something else, and a window that grabs the keyboard to ask a favour is
/// the wrong way to ask.
@MainActor
final class CrashReportWindowController: NSObject, AppWindowPresenter, NSWindowDelegate {
    private let scanner: CrashLogScanner
    /// Called a turn after the window closes, once it no longer counts as open. While it's
    /// open it holds back an automatic install, like every other window.
    private let onClosed: () -> Void
    private var window: NSWindow?
    private(set) var model: CrashReportModel?

    init(scanner: CrashLogScanner = CrashLogScanner(), onClosed: @escaping () -> Void) {
        self.scanner = scanner
        self.onClosed = onClosed
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Looks for a crash since the last look and, if there's one to offer, shows it. Does
    /// nothing while a report is already on screen: that one is still being answered, and
    /// the next look will find any newer crash.
    func offerNewCrash() {
        guard let deliver = CrashReporting.deliver, scanner.isOffering, !isVisible,
              let found = scanner.takeNewCrash() else { return }
        let model = CrashReportModel(report: found.report, count: found.count)
        model.deliver = deliver
        self.model = model
        // Not visible (checked above), so this only drops a window built for an earlier
        // report, whose view still points at that report's model.
        window = nil
        show()
    }

    func show() {
        guard let model else { return }
        if window == nil {
            let root = CrashReportView(
                model: model,
                onDone: { [weak self] in self?.window?.close() },
                onDontAskAgain: { [weak self] in
                    self?.scanner.isOffering = false
                    self?.window?.close()
                })
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "MacRazer Crash Report"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // Match the other windows: the green accent needs a dark ground.
            w.appearance = NSAppearance(named: .darkAqua)
            w.delegate = self
            w.center()
            window = w
        }
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        // Deferred: the window is still visible during `windowWillClose`, and anything that
        // asks "is a window open?" from here would get the wrong answer.
        DispatchQueue.main.async { [weak self] in self?.onClosed() }
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit

/// The system settings the decorations follow, in one place.
enum ReduceMotion {
    static var isOn: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func observe(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in handler() }
    }

    static func observeWake(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in handler() }
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import UserNotifications

/// Fires a system notification once when the mouse's battery drops below the same
/// threshold the UI itself already treats as "low" (see `Color.batteryLow`, <15%).
///
/// One notification per discharge episode: charging or a reading back at/above the
/// threshold re-arms it, so the ~15s poll cadence can't repeat the same alert every tick.
final class LowBatteryNotifier {
    static let threshold = 15
    private var armed = true

    /// Ask for notification permission once, early — so the system prompt appears at
    /// launch rather than the first time the battery happens to be low. No-op under
    /// `swift run` (no bundle identifier there — same dev-mode carve-out as `relaunch()`
    /// in Permissions.swift): UNUserNotificationCenter needs a real app bundle.
    static func requestAuthorizationIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Call on every battery reading. Charging or climbing back to/above the threshold
    /// re-arms the notification for the next time the mouse drops low.
    func notify(deviceName: String?, percent: Int, charging: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard !charging, percent < Self.threshold else {
            armed = true
            return
        }
        guard armed else { return }
        armed = false

        let content = UNMutableNotificationContent()
        content.title = "Battery Low"
        content.body = "\(deviceName ?? "Razer mouse") is at \(percent)% — charge it soon."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "low-battery", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

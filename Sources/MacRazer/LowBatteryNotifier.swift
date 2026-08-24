// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import UserNotifications

/// Battery percentage thresholds shared across the UI and the low-battery alert, so the
/// colour bands, the percent readout and the notification can't drift apart.
enum Battery {
    /// Below this, the battery reads as "low": the gauge, the percent readout and the usage
    /// chart's band turn red, and `LowBatteryAlertPolicy` fires its one notification.
    static let lowThresholdPercent = 15
    /// The alert re-arms only once the charge climbs back to here — deliberately above
    /// `lowThresholdPercent`. Without that gap, one garbage-but-accepted high reading (the
    /// poll state machine adopts a third consecutive outlier as the new baseline) would
    /// re-arm and let the next genuine low reading fire a duplicate alert.
    static let lowRearmPercent = 20
}

/// The pure decision core of the low-battery alert: given a reading, should we alert?
///
/// Split from delivery (`LowBatteryNotifier`) for the same reason as
/// `BatteryPollStateMachine` — no I/O, no clock, no bundle — so every arm/re-arm edge is
/// unit-testable by replaying readings.
struct LowBatteryAlertPolicy {
    private var armed = true

    /// A different physical mouse was bound, so this unit has never been alerted on.
    /// Deliberately NOT called for the same-session PID→serial key upgrade, which renames
    /// the *same* unit's storage — re-arming there would duplicate its alert.
    mutating func deviceChanged() { armed = true }

    /// Feed every battery reading. Returns true at most once per discharge episode.
    ///
    /// `charging` must be the *observed* charging flag, not `BatteryPollStateMachine`'s
    /// two-poll-confirmed one: that confirmation resets on any transient read failure, so a
    /// docked mouse reports "not charging" on the first good poll after one — which would
    /// fire a false "charge it soon" while it sits on the charger.
    mutating func shouldAlert(percent: Int, charging: Bool) -> Bool {
        if charging || percent >= Battery.lowRearmPercent {
            armed = true
            return false
        }
        guard percent < Battery.lowThresholdPercent, armed else { return false }
        armed = false
        return true
    }

    /// Delivery failed (notifications denied or undeliverable) — put the alert back so this
    /// discharge episode isn't silently skipped.
    mutating func rearmAfterFailedDelivery() { armed = true }
}

/// Delivers the low-battery alert.
///
/// `@unchecked Sendable` under the same discipline as `MouseController`, which owns it:
/// `policy` is touched only on the main queue (every call site is inside a `publish` block),
/// so it needs no synchronisation — the delivery callback hops back before re-arming.
final class LowBatteryNotifier: @unchecked Sendable {
    private var policy = LowBatteryAlertPolicy()

    /// Ask for notification permission once, early — so the system prompt appears at launch
    /// rather than the first time the battery happens to be low. No-op under `swift run`
    /// (no bundle identifier there, the same dev-mode carve-out as `PermissionsModel.relaunch()`):
    /// UNUserNotificationCenter needs a real app bundle.
    static func requestAuthorizationIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                FileHandle.standardError.write(Data("[MacRazer] notification authorization failed: \(error)\n".utf8))
            } else if !granted {
                FileHandle.standardError.write(Data("[MacRazer] notifications not permitted — low-battery alerts are off\n".utf8))
            }
        }
    }

    func deviceChanged() { policy.deviceChanged() }

    /// Call on every battery reading. `deviceKey` scopes the notification so two mice each
    /// hold their own alert instead of one silently replacing the other.
    func notify(deviceKey: String?, deviceName: String?, percent: Int, charging: Bool) {
        guard policy.shouldAlert(percent: percent, charging: charging) else { return }
        // The policy runs regardless of bundle (so dev runs still exercise it); only
        // delivery needs a real app bundle.
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = "Battery Low"
        content.body = "\(deviceName ?? "Razer mouse") is at \(percent)% — charge it soon."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "low-battery-\(deviceKey ?? "unknown")", content: content, trigger: nil)
        // Built before the delivery callback so the callback itself never captures `self`.
        // Never delivered → don't burn this discharge episode's one alert; the hop back to
        // the main queue is what keeps `policy` main-queue-owned.
        let rearm: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.policy.rearmAfterFailedDelivery() }
        }
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            FileHandle.standardError.write(Data("[MacRazer] low-battery notification failed: \(error)\n".utf8))
            rearm()
        }
    }
}

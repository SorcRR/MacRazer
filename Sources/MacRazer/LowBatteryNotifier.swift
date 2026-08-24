// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import UserNotifications

/// The pure decision core of the low-battery alert: given a reading, should we alert?
///
/// Split from delivery (`LowBatteryNotifier`) for the same reason as
/// `BatteryPollStateMachine` — no I/O, no clock, no bundle — so every arm/re-arm edge is
/// unit-testable by replaying readings.
struct LowBatteryAlertPolicy {
    private var armed = true

    /// Whether the next qualifying low reading would alert. Read by the notifier to spot the
    /// re-arm edge (so it can withdraw an already-delivered banner).
    var isArmed: Bool { armed }

    /// A different physical mouse was bound, so this unit has never been alerted on.
    /// Deliberately NOT called for the same-session PID→serial key upgrade, which renames
    /// the *same* unit's storage — re-arming there would duplicate its alert.
    mutating func deviceChanged() { armed = true }

    /// Feed every battery reading. Returns true at most once per discharge episode.
    ///
    /// `charging` must be the *observed* flag, not `BatteryPollStateMachine`'s
    /// two-poll-confirmed one: that confirmation resets on any transient read failure, so a
    /// docked mouse reports "not charging" on the first good poll after one — which would
    /// fire a false "charge it soon" while it sits on the charger.
    ///
    /// `nil` means the charging read itself failed. That is *not* "on battery": the mouse
    /// refuses commands around sleep exactly when it's most likely docked, so treating a
    /// failed read as discharging is the same false alert by another route. Unknown neither
    /// alerts nor re-arms — the next successful read decides.
    mutating func shouldAlert(percent: Int, charging: Bool?) -> Bool {
        if charging == true || percent >= Battery.lowRearmPercent {
            armed = true
            return false
        }
        guard charging == false else { return false }
        guard percent < Battery.lowThresholdPercent, armed else { return false }
        armed = false
        return true
    }

    /// Delivery failed transiently — put the alert back so this discharge episode isn't
    /// silently skipped. Permanent refusals (notifications switched off for the app) must
    /// NOT come through here: re-arming on those turns one denied alert into an attempt and
    /// a log line on every poll for the whole low-battery period.
    mutating func rearmAfterFailedDelivery() { armed = true }
}

/// Delivers the low-battery alert.
///
/// `@unchecked Sendable` under the same discipline as `MouseController`, which owns it:
/// `policy` is touched only on the main queue (every call site is inside a `publish` block),
/// so it needs no synchronisation — the delivery callback hops back before re-arming.
final class LowBatteryNotifier: @unchecked Sendable {
    private var policy = LowBatteryAlertPolicy()
    /// Cached notification authorization, main-queue owned. nil until the first check.
    ///
    /// Consulted *before* the policy so a denial can't silently burn this discharge's one
    /// alert: `add()` reports success even when notifications are switched off for the app
    /// (verified on macOS 26 — authorizationStatus .denied, add() completion error nil), so
    /// the delivery callback can't be the place this is caught.
    private var authorized: Bool?
    private var loggedDenial = false

    /// Set the presentation delegate and ask for permission once, early — so the system
    /// prompt appears at launch rather than the first time the battery happens to be low.
    ///
    /// Whole thing is a no-op under `swift run` (the same dev-mode carve-out as
    /// `PermissionsModel.relaunch()`). The guard covers `UNUserNotificationCenter.current()`
    /// itself, not just what we do with it: with no app bundle it raises
    /// NSInternalInconsistencyException ("bundleProxyForCurrentProcess is nil") and takes
    /// the whole app down at launch — and `swift run MacRazer` is a documented dev path.
    static func configureNotifications(delegate: UNUserNotificationCenterDelegate) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        // Without a delegate, macOS suppresses the banner whenever MacRazer is frontmost —
        // and clicking the status item activates it, so a low reading while the popover is
        // open would consume the one alert and show nothing.
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                FileHandle.standardError.write(Data("[MacRazer] notification authorization failed: \(error)\n".utf8))
            } else if !granted {
                FileHandle.standardError.write(Data("[MacRazer] notifications not permitted — low-battery alerts are off\n".utf8))
            }
        }
    }

    func deviceChanged() { policy.deviceChanged() }

    /// Re-read whether the user has allowed notifications. Called at launch and whenever the
    /// app returns to the foreground, so toggling the setting takes effect without a restart.
    func refreshAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        // Built outside the callback so the callback never captures `self` (same reason as
        // the delivery re-arm below).
        let apply: @Sendable (Bool) -> Void = { [weak self] ok in
            DispatchQueue.main.async { self?.authorized = ok }
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            apply(settings.authorizationStatus == .authorized
                  || settings.authorizationStatus == .provisional)
        }
    }

    /// Call on every battery reading. `deviceKey` scopes the notification so two mice each
    /// hold their own alert instead of one silently replacing the other.
    func notify(deviceKey: String?, deviceName: String?, percent: Int, charging: Bool?) {
        // Denied: leave the policy untouched so the alert is still pending if the user turns
        // notifications on mid-discharge. Logged once — this runs on every poll.
        if authorized == false {
            if !loggedDenial {
                loggedDenial = true
                let msg = "[MacRazer] notifications are off for MacRazer — low-battery alerts "
                    + "won't appear (System Settings › Notifications › MacRazer)\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
            return
        }
        let wasArmed = policy.isArmed
        guard policy.shouldAlert(percent: percent, charging: charging) else {
            // Re-armed on this tick (charged back up) — drop the delivered banner too, or
            // "is at 12% — charge it soon" sits in Notification Center for days after the
            // mouse is full.
            if !wasArmed, policy.isArmed { withdrawDelivered(deviceKey: deviceKey) }
            return
        }
        // The policy runs regardless of bundle (so dev runs still exercise it); only
        // delivery needs a real app bundle.
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = "Battery Low"
        content.body = "\(deviceName ?? "Razer mouse") is at \(percent)% — charge it soon."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.identifier(deviceKey: deviceKey), content: content, trigger: nil)
        // Built before the delivery callback so the callback itself never captures `self`.
        // Never delivered → don't burn this discharge episode's one alert; the hop back to
        // the main queue is what keeps `policy` main-queue-owned.
        let rearm: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.policy.rearmAfterFailedDelivery() }
        }
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            FileHandle.standardError.write(Data("[MacRazer] low-battery notification failed: \(error)\n".utf8))
            // Notifications switched off for the app is permanent for this run: re-arming
            // would retry (and log) every poll for the whole low-battery period.
            if (error as? UNError)?.code == .notificationsNotAllowed { return }
            rearm()
        }
    }

    private func withdrawDelivered(deviceKey: String?) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.identifier(deviceKey: deviceKey)])
    }

    private static func identifier(deviceKey: String?) -> String { "low-battery-\(deviceKey ?? "unknown")" }
}

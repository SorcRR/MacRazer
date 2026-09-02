// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import ServiceManagement

/// "Start MacRazer at login", backed by `SMAppService.mainApp` — the modern login-item API
/// (macOS 13+; the app targets 14), which is also what puts MacRazer in System Settings ›
/// General › Login Items so it can be switched off from outside the app.
///
/// **On by default.** A menu bar battery meter that silently stops existing after every
/// reboot, until you remember to go and open it, isn't a battery meter. The default is
/// applied at most once — the first launch of a build that has this feature — and only from a
/// real installed location. After that the user's choice is the record: turning it off here,
/// or in System Settings, is never undone by a later launch.
@MainActor
final class LaunchAtLogin: ObservableObject {
    /// Mirrors the *system's* registration rather than a preference of our own, and is re-read
    /// on demand: the user can flip this in System Settings without going through the app, and
    /// a switch that disagrees with Login Items is worse than no switch.
    @Published private(set) var isEnabled = false
    /// The item is registered but macOS wants the user to approve it before honouring it.
    /// Shown as on — that is what the app asked for — with a pointer to where to finish it.
    @Published private(set) var needsApproval = false
    /// A failed register/unregister, so the switch explains itself instead of just springing
    /// back to where it was.
    @Published private(set) var lastError: String?

    /// False under `swift run`, and when the app is running from a mounted DMG or a
    /// translocated copy: a login item recorded there points at a path that won't be MacRazer
    /// (or won't exist) at the next boot. See `AppLocation`.
    private(set) var isSupported: Bool

    private static let appliedDefaultKey = "launchAtLoginDefaultApplied"

    init() {
        isSupported = AppLocation.installedBundleURL != nil
        refresh()
        applyDefaultOnFirstRun()
    }

    /// Re-read the system's view. Cheap, and called whenever the app comes back to the
    /// foreground — the user may have just toggled MacRazer in System Settings and switched
    /// back, exactly as with the permission rechecks.
    func refresh() {
        guard isSupported else {
            isEnabled = false
            needsApproval = false
            return
        }
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ on: Bool) {
        guard isSupported else { return }
        lastError = nil
        // Whichever way this goes, the user has now expressed a choice — record that the
        // default no longer applies, so a failure here doesn't get silently "corrected" by
        // the first-run default on the next launch.
        UserDefaults.standard.set(true, forKey: Self.appliedDefaultKey)
        do {
            // Both calls throw when the service is already in the requested state, and the
            // switch can be driven from a published value that a System Settings change has
            // made stale — so decide from the live status, not from `isEnabled`.
            let status = SMAppService.mainApp.status
            let registered = status == .enabled || status == .requiresApproval
            if on, !registered {
                try SMAppService.mainApp.register()
            } else if !on, registered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = on
                ? "Couldn't turn this on — add MacRazer in System Settings › General › Login Items."
                : "Couldn't turn this off — remove MacRazer in System Settings › General › Login Items."
        }
        refresh()
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// The switch as an installed copy sees it, for the `render-ui` preview — `swift run` has
    /// no bundle, so the real state there is always the disabled one.
    func loadPreviewState() {
        isSupported = true
        isEnabled = true
        needsApproval = false
    }

    /// The default, applied once. Failure is deliberately *not* recorded as applied: the most
    /// likely cause is a first launch macOS hasn't settled yet, and the retry next launch
    /// costs nothing, whereas recording it would quietly cost the user the feature forever.
    private func applyDefaultOnFirstRun() {
        guard isSupported, !UserDefaults.standard.bool(forKey: Self.appliedDefaultKey) else { return }
        // Already registered — the user added MacRazer to Login Items by hand under an older
        // build. Nothing to do, and nothing to undo later.
        guard !isEnabled else {
            UserDefaults.standard.set(true, forKey: Self.appliedDefaultKey)
            return
        }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: Self.appliedDefaultKey)
        } catch {
            // Silent: an automatic default that failed is not something to interrupt a first
            // launch over. The switch shows the real state either way.
        }
        refresh()
    }
}

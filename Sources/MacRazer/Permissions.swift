// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import IOKit.hid

/// Single source of truth for the two macOS permissions MacRazer needs, and the actions to
/// grant them. Drives the first-run setup window (`PermissionsView`).
///
/// - **Input Monitoring** — required to open the Razer HID device for battery / DPI / polling
///   / lighting. macOS gates this because the device enumerates as a keyboard/mouse.
/// - **Accessibility** — required *only* for the button-remapping `CGEvent` tap.
@MainActor
final class PermissionsModel: ObservableObject {
    /// Input Monitoring granted (the blocking permission — nothing reads from the mouse without it).
    @Published private(set) var inputMonitoring = false
    /// Accessibility granted (optional — only the remap feature needs it).
    @Published private(set) var accessibility = false
    /// Input Monitoring is granted at the API level, but the *running* process still can't open
    /// the device — the grant only takes effect after a relaunch. The classic macOS TCC gotcha.
    @Published private(set) var needsRelaunch = false

    private weak var remapper: ButtonRemapper?
    private weak var controller: MouseController?

    init(remapper: ButtonRemapper? = nil, controller: MouseController? = nil) {
        self.remapper = remapper
        self.controller = controller
    }

    /// Both required permissions satisfied (Accessibility is optional, so it doesn't gate this).
    var allRequiredGranted: Bool { inputMonitoring }

    // MARK: - Status

    /// Re-read both permissions from the system. Call on launch, when the setup window appears,
    /// and whenever the app returns to the foreground (e.g. back from System Settings).
    func recheck() {
        inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        // refreshAccessibility also (re)installs the event tap once granted.
        remapper?.refreshAccessibility(prompt: false)
        accessibility = remapper?.accessibilityGranted ?? accessibility
        // Granted in System Settings but the device still reports a permission error → relaunch.
        if let c = controller, inputMonitoring, !c.connected, let err = c.lastError {
            needsRelaunch = err.contains("NotPermitted") || err.contains("0xe00002e2")
        } else {
            needsRelaunch = false
        }
    }

    // MARK: - Interactive grant (from the setup window)

    /// Fire the most useful action for the current state: the native prompt when undetermined,
    /// or System Settings when previously denied (the native prompt won't reappear once denied).
    func grantInputMonitoring() {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: break
        case kIOHIDAccessTypeDenied: openInputMonitoringSettings()
        default: _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        recheck()
    }

    func grantAccessibility() {
        remapper?.refreshAccessibility(prompt: true) // shows the native Accessibility prompt
        recheck()
    }

    func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Relaunch so a freshly-granted Input Monitoring permission takes effect. Only meaningful for
    /// the packaged `.app` (a no-op shape under `swift run`, which has no bundle to relaunch).
    func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    // MARK: - Preview

    /// Mixed state for the `render-permissions` preview command (IM granted, Accessibility not).
    func loadPreviewState() {
        inputMonitoring = true
        accessibility = false
        needsRelaunch = false
    }

    // MARK: - Helpers

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}

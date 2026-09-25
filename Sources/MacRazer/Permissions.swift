// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import IOKit.hid
import Security

/// The System Settings privacy panes this app sends users to — one place for the
/// `x-apple.systempreferences` deep links instead of hand-rolled copies per caller.
enum SystemSettingsPanes {
    static func openInputMonitoring() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}

/// Single source of truth for macOS permissions. USB HID needs Input Monitoring; the supported
/// Basilisk Bluetooth GATT path does not. Software actions on its DPI button additionally
/// require keyboard capture. Drives the first-run setup window (`PermissionsView`).
///
/// - **Input Monitoring** — required to open the Razer HID device for battery / DPI / polling
///   / lighting. macOS gates this because the device enumerates as a keyboard/mouse.
/// - **Accessibility** — required for remapping and posting synthesized actions.
/// - Keyboard-based DPI software actions also verify the actual event tap mask: a stale
///   Input Monitoring grant can leave mouse events enabled while excluding keyboard input.
@MainActor
final class PermissionsModel: ObservableObject {
    /// Input Monitoring granted (the blocking permission — nothing reads from the mouse without it).
    @Published private(set) var inputMonitoring = false
    /// The supported Basilisk can use CoreBluetooth without Input Monitoring.
    @Published private(set) var bluetoothAvailable = false
    /// Accessibility granted (optional — only the remap feature needs it).
    @Published private(set) var accessibility = false
    /// Input Monitoring is granted at the API level, but the *running* process still can't open
    /// the device — the grant only takes effect after a relaunch. The classic macOS TCC gotcha.
    @Published private(set) var needsRelaunch = false
    /// The automatic relaunch failed (translocated run from the DMG, no bundle under
    /// `swift run`) — tell the user to quit and reopen manually instead of doing nothing.
    @Published private(set) var relaunchFailed = false

    private weak var remapper: ButtonRemapper?
    private weak var controller: MouseController?

    init(remapper: ButtonRemapper? = nil, controller: MouseController? = nil) {
        self.remapper = remapper
        self.controller = controller
    }

    /// Both required permissions satisfied (Accessibility is optional, so it doesn't gate this).
    var allRequiredGranted: Bool { inputMonitoring || bluetoothAvailable }

    // MARK: - Status

    /// Re-read both permissions from the system. Call on launch, when the setup window appears,
    /// and whenever the app returns to the foreground (e.g. back from System Settings).
    func recheck() {
        inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        bluetoothAvailable = controller?.deviceIsBluetooth == true || HIDDevice.bluetoothBasiliskV3XName() != nil
        // refreshAccessibility also (re)installs the event tap once granted.
        remapper?.refreshAccessibility(prompt: false)
        accessibility = remapper?.accessibilityGranted ?? accessibility
        // Granted in System Settings but the device still reports a permission error → relaunch.
        if let c = controller, inputMonitoring, !c.connected, let err = c.lastError {
            needsRelaunch = HIDDevice.errorLooksPermissionDenied(err)
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

    func openInputMonitoringSettings() { SystemSettingsPanes.openInputMonitoring() }

    func openAccessibilitySettings() { SystemSettingsPanes.openAccessibility() }

    /// Relaunch so a freshly-granted Input Monitoring permission takes effect. Only meaningful for
    /// the packaged `.app` (a no-op shape under `swift run`, which has no bundle to relaunch).
    func relaunch() {
        relaunchFailed = false
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            // Only quit once the replacement instance actually launched — terminating on a
            // failed open (no bundle under `swift run`, app translocation) would turn
            // "Quit & Relaunch" into plain "Quit". But don't fail silently either: say so,
            // so the user quits and reopens manually instead of concluding the button is broken.
            Task { @MainActor in
                if app != nil, error == nil {
                    NSApp.terminate(nil)
                } else {
                    self.relaunchFailed = true
                }
            }
        }
    }

    // MARK: - Preview

    /// Mixed state for the `render-permissions` preview command (IM granted, Accessibility not).
    func loadPreviewState() {
        inputMonitoring = true
        accessibility = false
        needsRelaunch = false
    }

}

/// A hash-bound ad-hoc identity cannot retain privacy grants across executable changes.
enum AppCodeIdentity {
    static let isAdHoc: Bool = {
        var code: SecCode?
        var information: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let data = information as? [String: Any],
              let flags = data[kSecCodeInfoFlags as String] as? NSNumber else { return false }
        return flags.uint32Value & 0x2 != 0
    }()
}

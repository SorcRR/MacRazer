// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

/// What the popover says about a mouse it can't reach. Kept out of the view so tests can
/// check which message wins.
enum PopoverStatus {
    /// The card shown under the header while the mouse is unreachable.
    enum Notice: Equatable {
        case bluetooth
        case heldByAnotherApp
    }

    /// `noMouse`: no mouse name known, so the no-mouse card is up and says it there instead.
    static func notice(connected: Bool, onBluetooth: Bool, held: Bool, noMouse: Bool) -> Notice? {
        guard !connected else { return nil }
        if onBluetooth { return .bluetooth }
        if held && !noMouse { return .heldByAnotherApp }
        return nil
    }

    static func headerSubtitle(connected: Bool, supported: Bool, reconnecting: Bool, onBluetooth: Bool,
                               deviceKnown: Bool, held: Bool) -> String {
        if reconnecting && !connected { return "Reconnecting…" }
        if connected { return supported ? "Connected" : "Connected · limited support" }
        if onBluetooth { return "On Bluetooth" }
        // Before "Offline": a mouse held from launch has no name yet, but it is plugged in.
        if held { return "In use by another app" }
        if deviceKnown { return "Offline" }
        return "Connect a Razer mouse"
    }
}

/// The advice for a mouse another app holds exclusively (#139), shared by the popover and
/// the device test so they say the same thing.
enum HeldByAnotherApp {
    static let title = "Another app is using this mouse"
    static let apps = "Apps that remap keys or mice can do this, like Karabiner-Elements, SteerMouse or USB Overdrive."
    static let popoverDetail = "An app has taken the mouse for itself, so MacRazer can't reach it. \(apps) Turn off that app's control of this mouse, and MacRazer finds it again on its own."
    static let deviceTestWarning = "Another app has taken your mouse for itself, so the test can't reach it. \(apps) Turn off that app's control of this mouse and press Start again."
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import IOKit.hid

/// A Razer mouse that isn't on the verified list, as the support prompt needs to describe it.
struct UnsupportedMouse: Equatable {
    let pid: Int
    let name: String
    /// False when the mouse is plugged in but the app can't open it yet (no Input Monitoring).
    /// The prompt then leads with the permission instead of the test.
    let canControl: Bool
}

/// What the app remembers about asking for one model. Keyed by PID, not serial: a second unit
/// of the same model tells us nothing new, while the cable, dongle and Bluetooth PIDs of one
/// mouse are separate links that each need testing.
struct SupportPromptRecord: Codable, Equatable {
    var timesAsked = 0
    var lastAsked: Date?
    /// "Don't ask for this mouse" in the window, or Hide on the popover card.
    var declined = false
    /// A report for this PID went out, by Send or by opening the GitHub issue.
    var reported = false
}

/// When to ask someone with an unsupported mouse to run the device test. Pure, so the cases
/// that are slow to reach by hand (the reminder a week later, a model promoted in a later
/// release) are tested.
enum SupportPromptPolicy {
    /// The first ask and one reminder. After that only the popover card is left, which the
    /// person sees only when they open the popover anyway.
    static let maxAsks = 2
    static let reminderAfter: TimeInterval = 7 * 24 * 60 * 60

    static func shouldAsk(pid: Int, record: SupportPromptRecord, enabled: Bool, now: Date) -> Bool {
        // Checked here and not only by the caller: a model promoted in a later release stops
        // asking without anything having to clear its record.
        guard enabled, !RazerDevices.fullySupported(pid: pid) else { return false }
        guard !record.declined, !record.reported, record.timesAsked < maxAsks else { return false }
        guard let last = record.lastAsked else { return true }
        return now.timeIntervalSince(last) >= reminderAfter
    }

    /// The card at the top of the popover. Stays until the person reports or hides it, unlike
    /// the window, because it only shows when they've opened the popover themselves.
    static func showsCard(pid: Int, record: SupportPromptRecord, enabled: Bool) -> Bool {
        enabled && !RazerDevices.fullySupported(pid: pid) && !record.declined && !record.reported
    }
}

/// The prompt's settings and per-model records, kept in `UserDefaults`.
@MainActor
final class SupportPrompt: ObservableObject {
    static let shared = SupportPrompt()

    static let enabledKey = "supportPrompt.enabled"
    static let recordsKey = "supportPrompt.records"

    private let defaults: UserDefaults
    @Published private(set) var records: [Int: SupportPromptRecord]
    /// Settings › "Ask me to test unsupported mice".
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        // A record that fails to decode is treated as never asked: one extra prompt is the
        // worst that can happen.
        records = defaults.data(forKey: Self.recordsKey)
            .flatMap { try? JSONDecoder().decode([Int: SupportPromptRecord].self, from: $0) } ?? [:]
    }

    func record(pid: Int) -> SupportPromptRecord { records[pid] ?? SupportPromptRecord() }

    func shouldAsk(pid: Int, now: Date = Date()) -> Bool {
        SupportPromptPolicy.shouldAsk(pid: pid, record: record(pid: pid), enabled: isEnabled, now: now)
    }

    func showsCard(pid: Int) -> Bool {
        SupportPromptPolicy.showsCard(pid: pid, record: record(pid: pid), enabled: isEnabled)
    }

    func markAsked(pid: Int, now: Date = Date()) {
        update(pid) { $0.timesAsked += 1; $0.lastAsked = now }
    }

    func markDeclined(pid: Int) { update(pid) { $0.declined = true } }

    func markReported(pid: Int) { update(pid) { $0.reported = true } }

    private func update(_ pid: Int, _ change: (inout SupportPromptRecord) -> Void) {
        var record = record(pid: pid)
        change(&record)
        records[pid] = record
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.recordsKey) }
    }

    /// A Razer mouse plugged in by cable or dongle that the app can't open, because Input
    /// Monitoring is missing. Listing devices and reading their ids needs no permission.
    /// Supported models are left to the setup window, which already asks for the permission.
    static func mouseWithoutAccess() -> UnsupportedMouse? {
        guard !DeviceTestModel.inputMonitoringGranted else { return nil }
        let mice = HIDDevice.devices(matching: [
            kIOHIDVendorIDKey as String: Razer.vendorId,
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse,
        ])
        for device in mice {
            guard let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
                  !RazerDevices.fullySupported(pid: pid) else { continue }
            let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)?
                .trimmingCharacters(in: .whitespaces)
            let name = product.flatMap { $0.isEmpty ? nil : $0 } ?? RazerDevices.info(pid: pid)?.name ?? "Razer Mouse"
            return UnsupportedMouse(pid: pid, name: name, canControl: false)
        }
        return nil
    }
}

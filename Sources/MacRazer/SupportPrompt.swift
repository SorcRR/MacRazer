// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Combine
import Foundation

/// A Razer mouse the support prompt asks about: not on the verified list, partly verified, or
/// verified here but not on another way it connects (`RazerDevices.needsReport`).
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
    /// A report for this PID was sent. Opening the GitHub issue counts only in a build that
    /// can't send, where it is the one way to report.
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
        // asking without anything having to clear its record. A mouse fully supported on this
        // link is still asked about when another way it connects needs a report.
        guard enabled, RazerDevices.needsReport(pid: pid) else { return false }
        guard !record.declined, !record.reported, record.timesAsked < maxAsks else { return false }
        guard let last = record.lastAsked else { return true }
        return now.timeIntervalSince(last) >= reminderAfter
    }

    /// The card at the top of the popover. Stays until the person reports or hides it, unlike
    /// the window, because it only shows when they've opened the popover themselves.
    static func showsCard(pid: Int, record: SupportPromptRecord, enabled: Bool) -> Bool {
        enabled && RazerDevices.needsReport(pid: pid) && !record.declined && !record.reported
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

    /// Marks a model reported once a test's report is sent, from wherever the test was opened.
    /// Opening the GitHub issue counts only where Send isn't offered: nothing says the issue was
    /// filed, but without it a build that can't send could never stop asking.
    func trackReports(from model: DeviceTestModel) -> AnyCancellable {
        model.$sendState.combineLatest(model.$issueOpened)
            .sink { [weak self, weak model] state, issueOpened in
                // `report` is read off the model, not from the publishers: it is set before
                // either of these changes and cleared by `reset` before they go back.
                guard let model, state == .sent || (issueOpened && !model.canSend),
                      let pid = model.report?.device.productID else { return }
                self?.markReported(pid: pid)
            }
    }

    /// The first unverified mouse among `mice` when the app can't open it, because Input
    /// Monitoring is missing. Supported models are left to the setup window, which already
    /// asks for the permission.
    nonisolated static func mouseWithoutAccess(among mice: [HIDDevice.USBMouse], accessGranted: Bool) -> UnsupportedMouse? {
        guard !accessGranted,
              let mouse = mice.first(where: { !RazerDevices.fullySupported(pid: $0.pid) }) else { return nil }
        return UnsupportedMouse(pid: mouse.pid, name: mouse.name, canControl: false)
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

enum SnapshotDeviceTransition: Equatable {
    case unchanged
    case upgradedFromPID
    case switched
    case unresolvedSerial

    static func resolve(currentKey: String?, newKey: String, serial: String?, pidKey: String) -> Self {
        if newKey == currentKey { return .unchanged }
        guard serial != nil else { return .unresolvedSerial }
        if currentKey == pidKey { return .upgradedFromPID }
        return .switched
    }
}

/// The last trusted battery reading, kept separately from the bounded discharge history so
/// the popover can still show a useful, explicitly stale reference while the mouse is away.
struct LastBatterySnapshot: Codable, Equatable {
    let deviceKey: String
    let productID: Int
    let deviceName: String
    let percent: Int
    let observedAt: Date
    let estimatedHoursRemaining: Double?
    let wasCharging: Bool

    var estimateText: String? {
        guard let hours = estimatedHoursRemaining, hours.isFinite, hours >= 0 else { return nil }
        return BatteryHistory.formatEstimate(hours: hours)
    }

    var shortEstimateText: String? {
        guard let hours = estimatedHoursRemaining, hours.isFinite, hours >= 0 else { return nil }
        return "~\(BatteryHistory.formatDuration(hours: hours)) left"
    }

    @MainActor static let relativeAgeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    func sameDisplayedState(as other: LastBatterySnapshot?) -> Bool {
        guard let other else { return false }
        return deviceKey == other.deviceKey && productID == other.productID
            && deviceName == other.deviceName && percent == other.percent
            && wasCharging == other.wasCharging
            && estimateText == other.estimateText
    }

    fileprivate static func sameEstimate(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some, nil), (nil, .some): return false
        case let (.some(a), .some(b)): return abs(a - b) < 1
        }
    }

    var isValid: Bool {
        !deviceKey.isEmpty && !deviceName.isEmpty && (0...100).contains(percent)
            && (estimatedHoursRemaining.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

/// Stores one latest snapshot, not a time series. Updates are throttled to avoid writing
/// preferences on every battery poll; meaningful state changes and shutdown/sleep are saved
/// immediately.
final class LastBatterySnapshotStore {
    static let storageKey = "lastBatterySnapshot.v1"
    static let saveInterval: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var snapshots: [String: LastBatterySnapshot]?
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(_ deviceKey: String? = nil) -> LastBatterySnapshot? {
        lock.lock(); defer { lock.unlock() }
        let all = loadAllLocked()
        if let deviceKey { return all[deviceKey] }
        return all.values.max { $0.observedAt < $1.observedAt }
    }

    func save(_ snapshot: LastBatterySnapshot, previous: LastBatterySnapshot? = nil, force: Bool = false) {
        guard snapshot.isValid else { return }
        lock.lock(); defer { lock.unlock() }
        var all = loadAllLocked()
        let lastSaved = all[snapshot.deviceKey]
        let comparedWith = previous ?? lastSaved
        let stateChanged = comparedWith.map {
            $0.productID != snapshot.productID || $0.deviceName != snapshot.deviceName || $0.percent != snapshot.percent
                || $0.wasCharging != snapshot.wasCharging
                || estimateChanged($0.estimatedHoursRemaining, snapshot.estimatedHoursRemaining)
        } ?? true
        guard force || stateChanged
                || Date().timeIntervalSince(lastSaved?.observedAt ?? .distantPast) >= Self.saveInterval else { return }
        all[snapshot.deviceKey] = snapshot
        snapshots = all
        guard let data = try? encoder.encode(all) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func remove(_ deviceKey: String) {
        lock.lock(); defer { lock.unlock() }
        var all = loadAllLocked()
        all.removeValue(forKey: deviceKey)
        snapshots = all
        guard let data = try? encoder.encode(all) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        snapshots = [:]
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func loadAllLocked() -> [String: LastBatterySnapshot] {
        if let snapshots { return snapshots }
        guard let data = defaults.data(forKey: Self.storageKey) else {
            snapshots = [:]
            return [:]
        }
        let decoded = (try? decoder.decode([String: LastBatterySnapshot].self, from: data))
            ?? (try? decoder.decode(LastBatterySnapshot.self, from: data)).map { [$0.deviceKey: $0] }
            ?? [:]
        snapshots = decoded.filter { $0.key == $0.value.deviceKey && $0.value.isValid }
        return snapshots ?? [:]
    }

    private func estimateChanged(_ lhs: Double?, _ rhs: Double?) -> Bool {
        !LastBatterySnapshot.sameEstimate(lhs, rhs)
    }
}

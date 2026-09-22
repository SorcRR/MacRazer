// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// `MouseController.handOverHistory` runs when the connected mouse changes identity: a
/// different unit, or the same one whose serial number resolved after a PID fallback. Its
/// history holds minutes of samples in memory between throttled writes, so the order of
/// save, migrate and reopen decides whether they survive.
final class HistoryHandOverTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private let suiteName = "MacRazerTests-HistoryHandOver"
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// A history with an hour of samples, of which only the first has reached disk.
    private func historyWithUnsavedTail(key: String) -> BatteryHistory {
        let h = BatteryHistory(deviceKey: key, directory: dir, defaults: defaults, saveInterval: 3600)
        for i in 0...12 {
            h.record(percent: 90 - i / 6, charging: false, at: t0.addingTimeInterval(Double(i) * 300))
        }
        return h
    }

    private func onDisk(_ key: String) -> Int {
        BatteryHistory(deviceKey: key, directory: dir, defaults: defaults).samples.count
    }

    func testTheOutgoingHistoryIsOnDiskBeforeItIsMigrated() {
        // The bug an early draft had: saving after the migration wrote the old key's file
        // back, and the migration had moved only what was on disk.
        let outgoing = historyWithUnsavedTail(key: "00db")
        XCTAssertEqual(onDisk("00db"), 1, "precondition: most samples only in memory")
        var seenByMigrate: Int?
        _ = MouseController.handOverHistory(
            outgoing, outgoingKey: "00db",
            migrate: { old in seenByMigrate = self.onDisk(old) },
            makeIncoming: { BatteryHistory(deviceKey: "SERIAL", directory: self.dir, defaults: self.defaults) })
        XCTAssertEqual(seenByMigrate, outgoing.samples.count, "migrate must see every sample")
    }

    func testTheIncomingHistoryIsOpenedAfterTheMigration() {
        // Opening first would load the new key before the old data was moved to it.
        let outgoing = historyWithUnsavedTail(key: "00db")
        var order: [String] = []
        _ = MouseController.handOverHistory(
            outgoing, outgoingKey: "00db",
            migrate: { _ in order.append("migrate") },
            makeIncoming: {
                order.append("open")
                return BatteryHistory(deviceKey: "SERIAL", directory: self.dir, defaults: self.defaults)
            })
        XCTAssertEqual(order, ["migrate", "open"])
    }

    func testThePlaceholderIsNeverWritten() {
        // The app starts on a history that belongs to no device. Saving it would leave an
        // empty file behind on every launch.
        let placeholder = BatteryHistory(deviceKey: "default", directory: dir, defaults: defaults)
        var migrated = false
        _ = MouseController.handOverHistory(
            placeholder, outgoingKey: nil,
            migrate: { _ in migrated = true },
            makeIncoming: { BatteryHistory(deviceKey: "SERIAL", directory: self.dir, defaults: self.defaults) })
        XCTAssertFalse(migrated)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("battery-history-default.json").path))
    }
}

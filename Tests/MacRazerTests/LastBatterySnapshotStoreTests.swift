// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class LastBatterySnapshotStoreTests: XCTestCase {
    private func makeStore() throws -> (LastBatterySnapshotStore, UserDefaults, String) {
        let suiteName = "LastBatterySnapshotStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (LastBatterySnapshotStore(defaults: defaults), defaults, suiteName)
    }

    private func snapshot(key: String = "mouse-1", percent: Int = 84,
                          hours: Double? = 39, at date: Date = Date()) -> LastBatterySnapshot {
        LastBatterySnapshot(deviceKey: key, productID: 0x00BA,
                            deviceName: "Razer Basilisk V3 X HyperSpeed", percent: percent,
                            observedAt: date, estimatedHoursRemaining: hours, wasCharging: false)
    }

    func testPersistsOneSnapshotPerDeviceAndCanClearThem() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = snapshot(at: Date(timeIntervalSince1970: 1_700_000_000))
        store.save(first)
        XCTAssertEqual(store.load(), first)

        let latest = snapshot(key: "mouse-2", percent: 71, hours: 20)
        store.save(latest)
        XCTAssertEqual(store.load(), latest)
        XCTAssertEqual(store.load("mouse-1"), first)
        XCTAssertEqual(store.load("mouse-2"), latest)

        store.clear()
        XCTAssertNil(store.load())
    }

    func testRejectsInvalidSnapshotInsteadOfPersistingIt() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.save(snapshot(percent: 101), force: true)

        XCTAssertNil(store.load())
        XCTAssertNil(defaults.data(forKey: LastBatterySnapshotStore.storageKey))
    }

    func testLoadsLegacySingleSnapshotAndPreservesItWhenAnotherMouseSaves() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = snapshot(key: "mouse-1", at: Date(timeIntervalSince1970: 1_700_000_000))
        defaults.set(try JSONEncoder().encode(first), forKey: LastBatterySnapshotStore.storageKey)

        XCTAssertEqual(store.load("mouse-1"), first)
        store.save(snapshot(key: "mouse-2", percent: 71, hours: 20))
        XCTAssertEqual(store.load("mouse-1"), first)
        XCTAssertEqual(store.load("mouse-2")?.percent, 71)
    }

    func testFormatsTheSavedEstimateWithoutAdvancingIt() {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = snapshot(hours: 39.5, at: observedAt)

        XCTAssertEqual(saved.estimateText, "~1d 15h left (est.)")
        XCTAssertEqual(saved.shortEstimateText, "~1d 15h left")
        XCTAssertEqual(saved.observedAt, observedAt)
    }

    func testDeviceTransitionKeepsSameMouseAndDistinguishesUpgradeFromSwap() {
        XCTAssertEqual(SnapshotDeviceTransition.resolve(currentKey: "SERIAL-A", newKey: "SERIAL-A",
                                                        serial: "SERIAL-A", pidKey: "00ba"), .unchanged)
        XCTAssertEqual(SnapshotDeviceTransition.resolve(currentKey: "00ba", newKey: "SERIAL-A",
                                                        serial: "SERIAL-A", pidKey: "00ba"), .upgradedFromPID)
        XCTAssertEqual(SnapshotDeviceTransition.resolve(currentKey: "SERIAL-A", newKey: "SERIAL-B",
                                                        serial: "SERIAL-B", pidKey: "00ba"), .switched)
        XCTAssertEqual(SnapshotDeviceTransition.resolve(currentKey: nil, newKey: "00ba",
                                                        serial: nil, pidKey: "00ba"), .unresolvedSerial)
    }

    func testDisplayedStateIgnoresObservationTimeButTracksShownValues() {
        let first = snapshot(at: Date(timeIntervalSince1970: 1_700_000_000))
        let later = snapshot(at: Date(timeIntervalSince1970: 1_700_000_300))
        XCTAssertTrue(later.sameDisplayedState(as: first))
        XCTAssertFalse(snapshot(percent: 83).sameDisplayedState(as: first))
        XCTAssertFalse(snapshot(hours: 38.5).sameDisplayedState(as: first))
    }
}

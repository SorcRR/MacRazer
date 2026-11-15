// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class RememberedSerialTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "RememberedSerialTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    // MARK: - Store

    func testRemembersTheSerialPerLinkAcrossInstances() {
        RememberedSerialStore(defaults: defaults).remember("SERIAL-A", pid: 0x00EA, locationID: 0x0110_0000)
        // A new store reads what the last launch wrote.
        let store = RememberedSerialStore(defaults: defaults)
        XCTAssertEqual(store.serial(pid: 0x00EA, locationID: 0x0110_0000), "SERIAL-A")
    }

    func testAnotherPortOrModelHasNoRememberedSerial() {
        let store = RememberedSerialStore(defaults: defaults)
        store.remember("SERIAL-A", pid: 0x00EA, locationID: 0x0110_0000)
        XCTAssertNil(store.serial(pid: 0x00EA, locationID: 0x0120_0000))
        XCTAssertNil(store.serial(pid: 0x00EB, locationID: 0x0110_0000))
    }

    func testANewSerialOnTheSameLinkReplacesTheOldOne() {
        let store = RememberedSerialStore(defaults: defaults)
        store.remember("SERIAL-A", pid: 0x00EA, locationID: 1)
        store.remember("SERIAL-B", pid: 0x00EA, locationID: 1)
        store.remember("SERIAL-C", pid: 0x00EA, locationID: 2)
        XCTAssertEqual(store.serial(pid: 0x00EA, locationID: 1), "SERIAL-B")
        XCTAssertEqual(store.serial(pid: 0x00EA, locationID: 2), "SERIAL-C")
    }

    // MARK: - Key choice

    func testTheReportedSerialWinsOverEverythingElse() {
        XCTAssertEqual(DeviceIdentity.key(probed: "SERIAL-B", sessionKey: "SERIAL-A",
                                          remembered: "SERIAL-C", pidKey: "00ea"), "SERIAL-B")
    }

    func testAFailedReadOnAReconnectKeepsTheSessionKey() {
        XCTAssertEqual(DeviceIdentity.key(probed: nil, sessionKey: "SERIAL-A",
                                          remembered: "SERIAL-C", pidKey: "00ea"), "SERIAL-A")
    }

    /// The bug: after a restart the mouse missed the serial read, the app used `00ea` and
    /// showed no profiles or remaps although they were all saved under the serial.
    func testAFailedReadOnLaunchUsesTheSerialLastSeenOnThisLink() {
        XCTAssertEqual(DeviceIdentity.key(probed: nil, sessionKey: nil,
                                          remembered: "SERIAL-A", pidKey: "00ea"), "SERIAL-A")
    }

    func testThePIDOnlyWhenNoSerialWasEverSeen() {
        XCTAssertEqual(DeviceIdentity.key(probed: nil, sessionKey: nil,
                                          remembered: nil, pidKey: "00ea"), "00ea")
    }

    // MARK: - Retry

    func testAnUnknownSerialIsAskedAgainAfterTheInterval() {
        let now = Date()
        XCTAssertTrue(DeviceIdentity.serialRetryDue(serialKnown: false, lastAttempt: nil, now: now))
        XCTAssertFalse(DeviceIdentity.serialRetryDue(serialKnown: false, lastAttempt: now.addingTimeInterval(-3),
                                                     now: now, interval: 10))
        XCTAssertTrue(DeviceIdentity.serialRetryDue(serialKnown: false, lastAttempt: now.addingTimeInterval(-10),
                                                    now: now, interval: 10))
    }

    func testAKnownSerialIsNeverAskedAgain() {
        XCTAssertFalse(DeviceIdentity.serialRetryDue(serialKnown: true, lastAttempt: nil, now: Date()))
        XCTAssertFalse(DeviceIdentity.serialRetryDue(serialKnown: true, lastAttempt: .distantPast, now: Date()))
    }
}

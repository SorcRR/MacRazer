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
        XCTAssertEqual(DeviceIdentity.key(probed: "SERIAL-B", sessionKey: "SERIAL-A", sessionIsThisLink: true,
                                          remembered: "SERIAL-C", pidKey: "00ea"), "SERIAL-B")
    }

    func testAFailedReadOnAReconnectKeepsTheSessionKey() {
        XCTAssertEqual(DeviceIdentity.key(probed: nil, sessionKey: "SERIAL-A", sessionIsThisLink: true,
                                          remembered: "SERIAL-C", pidKey: "00ea"), "SERIAL-A")
    }

    /// The bug: after a restart the mouse missed the serial read, the app used `00ea` and
    /// showed no profiles or remaps although they were all saved under the serial.
    func testAFailedReadOnLaunchUsesTheSerialLastSeenOnThisLink() {
        XCTAssertEqual(DeviceIdentity.key(probed: nil, sessionKey: nil, sessionIsThisLink: false,
                                          remembered: "SERIAL-A", pidKey: "00ea"), "SERIAL-A")
    }

    func testThePIDOnlyWhenNoSerialWasEverSeen() {
        XCTAssertEqual(DeviceIdentity.key(probed: nil, sessionKey: nil, sessionIsThisLink: false,
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

    func testAMouseThatAnsweredWithoutASerialIsAskedOnlyRarely() {
        let now = Date()
        XCTAssertFalse(DeviceIdentity.serialRetryDue(serialKnown: false, serialAbsent: true,
                                                     lastAttempt: now.addingTimeInterval(-60), now: now,
                                                     interval: 10, absentInterval: 300))
        // Not never: a waking mouse can refuse the read or answer with zeros.
        XCTAssertTrue(DeviceIdentity.serialRetryDue(serialKnown: false, serialAbsent: true,
                                                    lastAttempt: now.addingTimeInterval(-300), now: now,
                                                    interval: 10, absentInterval: 300))
    }

    // MARK: - Reopen

    func testALateSerialThatMatchesTheKeyKeepsTheHandle() {
        // The remembered serial was right, or a plug event only cleared the in-memory one.
        XCTAssertFalse(DeviceIdentity.reopensAfterRetry(probed: "SERIAL-A", sessionKey: "SERIAL-A"))
    }

    func testALateSerialThatChangesTheKeyReopens() {
        XCTAssertTrue(DeviceIdentity.reopensAfterRetry(probed: "SERIAL-A", sessionKey: "00ea"), "from the PID key")
        XCTAssertTrue(DeviceIdentity.reopensAfterRetry(probed: "SERIAL-B", sessionKey: "SERIAL-A"), "another unit")
        XCTAssertTrue(DeviceIdentity.reopensAfterRetry(probed: "SERIAL-A", sessionKey: nil))
    }

    // MARK: - Another link

    /// Mouse A's key must not stick to mouse C, plugged in later, when C's link remembers C.
    func testAnotherLinksSessionKeyGivesWayToThisLinksRememberedSerial() {
        XCTAssertEqual(DeviceIdentity.key(probed: nil, sessionKey: "SERIAL-A", sessionIsThisLink: false,
                                          remembered: "SERIAL-C", pidKey: "00ea"), "SERIAL-C")
    }

    /// The same mouse moved from its dongle to its cable: a new link with nothing remembered.
    func testAnotherLinksSessionKeyStillBeatsThePID() {
        XCTAssertEqual(DeviceIdentity.key(probed: nil, sessionKey: "SERIAL-A", sessionIsThisLink: false,
                                          remembered: nil, pidKey: "00eb"), "SERIAL-A")
    }

    // MARK: - Classifying a serial read

    private func reply(_ text: String) -> RazerReport {
        var report = RazerReport(commandClass: 0x00, commandId: 0x82, dataSize: 0x16)
        for (i, byte) in text.utf8.prefix(22).enumerated() { report.arguments[i] = byte }
        return report
    }

    func testARealSerialIsKept() {
        XCTAssertEqual(DeviceIdentity.classify(.success(reply("PM2219H12345678"))), .serial("PM2219H12345678"))
    }

    func testBlanksAndZerosMeanNoSerial() {
        XCTAssertEqual(DeviceIdentity.classify(.success(reply(""))), .absent)
        XCTAssertEqual(DeviceIdentity.classify(.success(reply("000000000000"))), .absent)
    }

    func testARefusalIsItsOwnAnswer() {
        XCTAssertEqual(DeviceIdentity.classify(.failure(HIDDevice.HIDError.commandFailed)), .refused)
        XCTAssertEqual(DeviceIdentity.classify(.failure(HIDDevice.HIDError.notSupported)), .refused)
    }

    /// A mouse waking after a restart can refuse for a while: the first refusals stay on the
    /// short retry, or its settings stay hidden for minutes. Only one that keeps refusing backs off.
    func testRefusalsBackOffOnlyOnceTheyKeepComing() {
        for count in 1..<DeviceIdentity.refusalsBeforeBackoff {
            XCTAssertFalse(DeviceIdentity.refusalsBackOff(count), "refusal \(count)")
        }
        XCTAssertTrue(DeviceIdentity.refusalsBackOff(DeviceIdentity.refusalsBeforeBackoff))
        XCTAssertTrue(DeviceIdentity.refusalsBackOff(DeviceIdentity.refusalsBeforeBackoff + 1))
    }

    /// An asleep mouse must stay on the short retry, or the restart bug comes back.
    func testNoAnswerIsAskedAgainSoon() {
        XCTAssertEqual(DeviceIdentity.classify(.failure(HIDDevice.HIDError.timeout)), .noAnswer)
        XCTAssertEqual(DeviceIdentity.classify(.failure(HIDDevice.HIDError.badResponse)), .noAnswer)
        XCTAssertEqual(DeviceIdentity.classify(.failure(HIDDevice.HIDError.getReportFailed(-1))), .noAnswer)
    }
}

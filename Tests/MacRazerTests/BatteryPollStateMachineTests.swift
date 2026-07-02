// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class BatteryPollStateMachineTests: XCTestCase {
    // raw 217 → 85%; raw values chosen so percent math is unambiguous.
    private let raw85: UInt8 = 217
    private let raw84: UInt8 = 215

    func testTwoFailureDebounceBeforeOffline() {
        var m = BatteryPollStateMachine()
        XCTAssertEqual(m.handle(.failure(deviceGone: false)), .pendingOffline,
                       "a single transient wireless timeout must not flap the UI")
        XCTAssertEqual(m.handle(.failure(deviceGone: false)), .offline(deviceGone: false))
    }

    func testImmediateOfflineBypassesDebounce() {
        var m = BatteryPollStateMachine()
        XCTAssertEqual(m.handle(.failure(deviceGone: true), immediateOffline: true),
                       .offline(deviceGone: true),
                       "an IOKit removal is definitive — no debounce")
    }

    func testSuccessResetsTheDebounce() {
        var m = BatteryPollStateMachine()
        _ = m.handle(.failure(deviceGone: false))
        _ = m.handle(.battery(raw: raw85, charging: false))
        XCTAssertEqual(m.handle(.failure(deviceGone: false)), .pendingOffline,
                       "failure count restarts after a good read")
    }

    func testRawZeroIsNotReadyNotZeroPercent() {
        var m = BatteryPollStateMachine()
        XCTAssertEqual(m.handle(.battery(raw: 0, charging: false)), .notReady)
        XCTAssertTrue(m.lastReadOK)
        XCTAssertFalse(m.batteryReady, "keep polling fast until a real value arrives")
    }

    func testWildJumpRejectedTwiceThenAcceptedAsNewBaseline() {
        var m = BatteryPollStateMachine()
        XCTAssertEqual(m.handle(.battery(raw: 178, charging: false)), // 70%
                       .reading(percent: 70, isCharging: false, recordSample: true))
        // Post-wake garbage 0xFF → 100%: a >20-point swing between polls is implausible.
        XCTAssertEqual(m.handle(.battery(raw: 0xFF, charging: false)), .notReady)
        XCTAssertEqual(m.handle(.battery(raw: 0xFF, charging: false)), .notReady)
        // Persisting for a third poll means it's not a blip — accept as the new baseline.
        XCTAssertEqual(m.handle(.battery(raw: 0xFF, charging: false)),
                       .reading(percent: 100, isCharging: false, recordSample: true))
    }

    func testPlausibleDropIsAcceptedOutright() {
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: raw85, charging: false))
        XCTAssertEqual(m.handle(.battery(raw: raw84, charging: false)),
                       .reading(percent: 84, isCharging: false, recordSample: true))
    }

    func testChargingNeedsSecondPollConfirmation() {
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: raw85, charging: false))
        // First charging sight: not trusted, and the tick isn't logged.
        XCTAssertEqual(m.handle(.battery(raw: raw85, charging: true)),
                       .reading(percent: 85, isCharging: false, recordSample: false))
        // Second consecutive: confirmed.
        XCTAssertEqual(m.handle(.battery(raw: raw85, charging: true)),
                       .reading(percent: 85, isCharging: true, recordSample: true))
        // Dropping back to not-charging applies immediately.
        XCTAssertEqual(m.handle(.battery(raw: raw85, charging: false)),
                       .reading(percent: 85, isCharging: false, recordSample: true))
    }

    func testOneOffGarbageChargingByteNeverConfirms() {
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: raw85, charging: false))
        _ = m.handle(.battery(raw: raw85, charging: true))  // garbage blip
        XCTAssertEqual(m.handle(.battery(raw: raw85, charging: false)),
                       .reading(percent: 85, isCharging: false, recordSample: true))
        // The blip was never confirmed, so nothing destructive (a history reset) happened.
    }

    func testFailureClearsPendingChargeConfirm() {
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: raw85, charging: true)) // pending
        _ = m.handle(.failure(deviceGone: false))          // link dropped
        XCTAssertEqual(m.handle(.battery(raw: raw85, charging: true)),
                       .reading(percent: 85, isCharging: false, recordSample: false),
                       "a stale pending confirm must not survive a connection drop")
    }

    func testDeviceChangedClearsPendingChargeConfirm() {
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: raw85, charging: true)) // pending on mouse A
        m.deviceChanged()                                   // swapped to mouse B
        XCTAssertEqual(m.handle(.battery(raw: raw85, charging: true)),
                       .reading(percent: 85, isCharging: false, recordSample: false),
                       "mouse A's pending confirm must not auto-confirm mouse B's first read")
    }

    func testAliveNoBatteryMarksReady() {
        var m = BatteryPollStateMachine()
        XCTAssertEqual(m.handle(.aliveNoBattery), .aliveNoBattery)
        XCTAssertTrue(m.lastReadOK)
        XCTAssertTrue(m.batteryReady)
    }

    func testRejectionDoesNotDisturbReadiness() {
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: 178, charging: false)) // 70%, ready
        _ = m.handle(.battery(raw: 0xFF, charging: false)) // rejected garbage
        XCTAssertTrue(m.batteryReady,
                      "a mid-session rejected blip keeps the slow poll cadence (matches pre-extraction behavior)")
    }
}

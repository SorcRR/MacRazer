// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class LowBatteryAlertPolicyTests: XCTestCase {
    private let low = Battery.lowThresholdPercent      // 15
    private let rearm = Battery.lowRearmPercent        // 20

    func testAlertsOnceWhenDroppingBelowThreshold() {
        var p = LowBatteryAlertPolicy()
        XCTAssertFalse(p.shouldAlert(percent: low, charging: false), "at the threshold is not below it")
        XCTAssertTrue(p.shouldAlert(percent: low - 1, charging: false))
    }

    func testDoesNotRepeatWhileStayingLow() {
        var p = LowBatteryAlertPolicy()
        XCTAssertTrue(p.shouldAlert(percent: 14, charging: false))
        // The poll loop keeps feeding readings every ~15s all the way down.
        for pct in stride(from: 13, through: 0, by: -1) {
            XCTAssertFalse(p.shouldAlert(percent: pct, charging: false), "re-alerted at \(pct)%")
        }
    }

    func testChargingSuppressesAndRearms() {
        var p = LowBatteryAlertPolicy()
        XCTAssertTrue(p.shouldAlert(percent: 10, charging: false))
        XCTAssertFalse(p.shouldAlert(percent: 10, charging: true), "never alert while charging")
        // Docked and re-armed; unplugged again while still low → a new episode alerts.
        XCTAssertTrue(p.shouldAlert(percent: 10, charging: false))
    }

    func testRearmNeedsHysteresisNotJustCrossingBackOverTheThreshold() {
        var p = LowBatteryAlertPolicy()
        XCTAssertTrue(p.shouldAlert(percent: 14, charging: false))
        // A garbage-but-accepted reading between the two thresholds must NOT re-arm, or the
        // next genuine low reading fires a duplicate alert for the same discharge.
        XCTAssertFalse(p.shouldAlert(percent: low, charging: false))
        XCTAssertFalse(p.shouldAlert(percent: rearm - 1, charging: false))
        XCTAssertFalse(p.shouldAlert(percent: 14, charging: false), "duplicate after a mid-band blip")
        // A real recharge clears the hysteresis band and re-arms.
        XCTAssertFalse(p.shouldAlert(percent: rearm, charging: false))
        XCTAssertTrue(p.shouldAlert(percent: 14, charging: false))
    }

    func testDeviceChangeRearmsForTheNewMouse() {
        var p = LowBatteryAlertPolicy()
        XCTAssertTrue(p.shouldAlert(percent: 10, charging: false))
        XCTAssertFalse(p.shouldAlert(percent: 9, charging: false))
        // A second, already-low mouse has never been alerted on.
        p.deviceChanged()
        XCTAssertTrue(p.shouldAlert(percent: 9, charging: false))
    }

    func testFailedDeliveryRearmsSoTheEpisodeIsNotSkipped() {
        var p = LowBatteryAlertPolicy()
        XCTAssertTrue(p.shouldAlert(percent: 10, charging: false))
        p.rearmAfterFailedDelivery() // notifications denied — nothing was shown
        XCTAssertTrue(p.shouldAlert(percent: 10, charging: false))
    }

    /// The regression this policy exists for: `BatteryPollStateMachine` clears its
    /// two-poll charge confirmation on any transient read failure, so a docked mouse
    /// reports `isCharging == false` on the next good poll. Feeding that debounced flag
    /// here would fire "charge it soon" while the mouse sits on the charger.
    func testObservedChargingFlagIsWhatSuppressesTheAlert() {
        var machine = BatteryPollStateMachine()
        func feed(raw: UInt8, charging: Bool) -> BatteryPollStateMachine.Verdict {
            machine.handle(.battery(raw: raw, charging: charging), immediateOffline: false)
        }
        let lowRaw = UInt8(10 * 255 / 100) // ~10%
        _ = feed(raw: lowRaw, charging: true)
        _ = feed(raw: lowRaw, charging: true) // confirmed charging by now
        _ = machine.handle(.failure(deviceGone: false), immediateOffline: false)
        _ = machine.handle(.failure(deviceGone: false), immediateOffline: false)
        let verdict = feed(raw: lowRaw, charging: true)

        guard case .reading(let pct, let isCharging, _) = verdict else {
            return XCTFail("expected a reading, got \(verdict)")
        }
        XCTAssertFalse(isCharging, "the confirmation resets after a failure — this is the trap")

        // The assertion that actually pins the wiring: feeding the DEBOUNCED flag fires a
        // false alert for a mouse that is plainly on the charger...
        var wrong = LowBatteryAlertPolicy()
        XCTAssertTrue(wrong.shouldAlert(percent: pct, charging: isCharging),
                      "regression guard: the debounced flag is what would misfire")
        // ...while the observed flag — what MouseController actually passes — suppresses it.
        var right = LowBatteryAlertPolicy()
        XCTAssertFalse(right.shouldAlert(percent: pct, charging: true))
    }

    func testUnknownChargingNeitherAlertsNorRearms() {
        var p = LowBatteryAlertPolicy()
        // The charging read failed: "don't know" must not be taken as "on battery".
        XCTAssertFalse(p.shouldAlert(percent: 10, charging: nil))
        // Still armed — a later confirmed-discharging read alerts normally.
        XCTAssertTrue(p.shouldAlert(percent: 10, charging: false))
        // And an unknown read afterwards doesn't re-arm it either.
        XCTAssertFalse(p.shouldAlert(percent: 10, charging: nil))
        XCTAssertFalse(p.shouldAlert(percent: 10, charging: false))
    }
}

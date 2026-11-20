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

    // MARK: - Poll cadence

    private typealias Cadence = BatteryPollStateMachine.Cadence

    func testCadenceFollowsTheConnection() {
        var m = BatteryPollStateMachine()
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.settling, "nothing known yet: look again soon")
        _ = m.handle(.battery(raw: 0, charging: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.settling, "answering but not ready: stay fast")
        _ = m.handle(.battery(raw: raw85, charging: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.connected)
        _ = m.handle(.failure(deviceGone: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.confirming, "one failure: confirm it at once")
        _ = m.handle(.failure(deviceGone: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.settling, "confirmed offline: catch a return quickly")
    }

    func testAnUnreachableMouseBacksOffAfterAMinute() {
        // The case this exists for: a mouse asleep behind its dongle overnight was polled
        // every 4 seconds until it woke.
        var m = BatteryPollStateMachine()
        _ = m.handle(.failure(deviceGone: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.confirming, "the first failure is unconfirmed")
        for poll in 2..<Cadence.fastPolls {
            _ = m.handle(.failure(deviceGone: false))
            XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.settling, "poll \(poll) should still be fast")
        }
        _ = m.handle(.failure(deviceGone: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.asleep)
        _ = m.handle(.failure(deviceGone: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.asleep, "stays backed off")
        _ = m.handle(.battery(raw: raw85, charging: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.connected, "an answer ends the back-off")
    }

    func testAMouseThatKeepsRefusingTheReadBacksOffToo() {
        // A refused battery read arrives as raw 0 with the link up (seen on the HyperSpeed
        // around sleep). Without counting these, a mouse stuck refusing would be polled
        // every 4 seconds forever, just as before.
        var m = BatteryPollStateMachine()
        for _ in 0..<Cadence.fastPolls { _ = m.handle(.battery(raw: 0, charging: false)) }
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.asleep)
    }

    func testNothingPluggedInPollsRarely() {
        // HIDMonitor reports supported USB and Bluetooth devices coming back; this is only
        // a safety net if its registration failed.
        var m = BatteryPollStateMachine()
        _ = m.handle(.failure(deviceGone: true), immediateOffline: true)
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.unplugged)
        XCTAssertEqual(Cadence.unplugged, 120)
    }

    func testAReplugAfterALongAbsenceGetsFastPollsAgain() {
        // Backed off while asleep, then the dongle was pulled and put back. The device on
        // the far side is new to us, and waiting 30 seconds to read it would look broken.
        var m = BatteryPollStateMachine()
        for _ in 0..<(Cadence.fastPolls + 5) { _ = m.handle(.failure(deviceGone: false)) }
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.asleep)
        _ = m.handle(.failure(deviceGone: true), immediateOffline: true)
        _ = m.handle(.failure(deviceGone: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.settling)
    }

    func testAMouseInUseIsReadMoreOften() {
        // Nothing on the USB side reports a mouse being switched off, so the gap between
        // reads is how long the app keeps showing a mouse that has gone. Switching one off is
        // done with a hand on it, so that is when the gap is worth paying for.
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: raw85, charging: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: true), Cadence.inUse)
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.connected)
    }

    func testPointerActivityDoesNotDisturbTheOtherCadences() {
        // Being at the machine says nothing about a mouse that is away, or one whose failure
        // is still unconfirmed: those ladders are already as fast as they need to be.
        var m = BatteryPollStateMachine()
        _ = m.handle(.failure(deviceGone: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: true), Cadence.confirming)
        for _ in 0..<Cadence.fastPolls { _ = m.handle(.failure(deviceGone: false)) }
        XCTAssertEqual(m.nextPollInterval(pointerActive: true), Cadence.asleep)
        _ = m.handle(.failure(deviceGone: true), immediateOffline: true)
        XCTAssertEqual(m.nextPollInterval(pointerActive: true), Cadence.unplugged)
    }

    func testAnUnconfirmedFailureIsCheckedStraightAway() {
        // The UI still shows the mouse as connected, with its remaps live, until a second
        // failure agrees. Waiting the old 4s between the two was most of the time it took to
        // notice a mouse that had gone.
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: raw85, charging: false))
        XCTAssertEqual(m.handle(.failure(deviceGone: false)), .pendingOffline)
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.confirming)
        XCTAssertEqual(m.handle(.failure(deviceGone: false)), .offline(deviceGone: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.settling, "confirmed: back to the normal ladder")
    }

    func testADeviceThatVanishedBetweenPollsIsConfirmedFast() {
        // Without HIDMonitor (registration can fail), the first poll to find nothing is still
        // only one failure. Confirming that in two minutes would leave the UI lying.
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: raw85, charging: false))
        XCTAssertEqual(m.handle(.failure(deviceGone: true)), .pendingOffline)
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.confirming)
        _ = m.handle(.failure(deviceGone: true))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.unplugged, "once it is confirmed, settle down")
    }

    func testAnImmediateOfflineNeedsNoConfirming() {
        // An IOKit removal is definitive, so there is nothing to confirm and no reason to
        // poll again in half a second.
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: raw85, charging: false))
        XCTAssertEqual(m.handle(.failure(deviceGone: true), immediateOffline: true),
                       .offline(deviceGone: true))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.unplugged)
    }

    func testARejectedBlipKeepsTheConnectedCadence() {
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: 178, charging: false))  // 70%
        _ = m.handle(.battery(raw: 0xFF, charging: false)) // rejected garbage
        XCTAssertEqual(m.nextPollInterval(pointerActive: false), Cadence.connected,
                       "one bad value from a live mouse is not a reason to poll harder")
    }

    // MARK: - Nobody at the Mac (#142)

    func testAnEmptyDeskStopsEveryPollThatTalksToTheMouse() {
        // Each read counts as user activity and keeps the display awake, so none of them
        // runs while nobody is there: not for a working mouse, a settling one or a sleeping one.
        var m = BatteryPollStateMachine()
        XCTAssertNil(m.nextPollInterval(pointerActive: false, userAway: true), "settling")
        _ = m.handle(.battery(raw: raw85, charging: false))
        XCTAssertNil(m.nextPollInterval(pointerActive: false, userAway: true), "connected")
        _ = m.handle(.failure(deviceGone: false))
        _ = m.handle(.failure(deviceGone: false))
        for _ in 0..<Cadence.fastPolls { _ = m.handle(.failure(deviceGone: false)) }
        XCTAssertNil(m.nextPollInterval(pointerActive: false, userAway: true), "asleep")
        _ = m.handle(.aliveNoBattery)
        XCTAssertNil(m.nextPollInterval(pointerActive: false, userAway: true), "battery-less")
    }

    func testAPendingFailureIsConfirmedEvenWithNobodyThere() {
        // Until the second read, the mouse still shows connected with its remaps live.
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: raw85, charging: false))
        _ = m.handle(.failure(deviceGone: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: false, userAway: true), Cadence.confirming)
        _ = m.handle(.failure(deviceGone: false))
        XCTAssertNil(m.nextPollInterval(pointerActive: false, userAway: true), "confirmed: now it can stop")
    }

    func testNothingPluggedInKeepsItsSafetyNet() {
        // No device means no reads to keep the display awake with.
        var m = BatteryPollStateMachine()
        _ = m.handle(.failure(deviceGone: true), immediateOffline: true)
        XCTAssertEqual(m.nextPollInterval(pointerActive: false, userAway: true), Cadence.unplugged)
    }

    func testSomeoneBackGetsTheOrdinaryCadence() {
        var m = BatteryPollStateMachine()
        _ = m.handle(.battery(raw: raw85, charging: false))
        XCTAssertEqual(m.nextPollInterval(pointerActive: true, userAway: false), Cadence.inUse)
        XCTAssertEqual(m.nextPollInterval(pointerActive: false, userAway: false), Cadence.connected)
    }
}

final class UserPresenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testPresentAtLaunchAndAwayAfterTheThreshold() {
        let p = UserPresence(now: t0)
        XCTAssertFalse(p.isAway(now: at(UserPresence.awayAfter - 1)))
        XCTAssertTrue(p.isAway(now: at(UserPresence.awayAfter)))
    }

    func testInputKeepsSomeonePresent() {
        var p = UserPresence(now: t0)
        p.observe(secondsSinceInput: 5, now: at(25)) // input at 20
        XCTAssertFalse(p.isAway(now: at(20 + UserPresence.awayAfter - 1)))
        XCTAssertTrue(p.isAway(now: at(20 + UserPresence.awayAfter)))
    }

    func testOnlyInputAfterAWakeCounts() {
        // If the counters skip the time asleep, input from before the sleep is dated just
        // before the wake. A Power Nap wake must not read as someone at the desk.
        var p = UserPresence(now: t0)
        p.woke(at: at(3600))
        p.observe(secondsSinceInput: 2, now: at(3601)) // "a second before the wake"
        XCTAssertTrue(p.isAway(now: at(3601)))
        p.observe(secondsSinceInput: 0, now: at(3605)) // a hand on the mouse after it
        XCTAssertFalse(p.isAway(now: at(3605)))
    }

    func testOlderInputNeverMovesTheClockBack() {
        var p = UserPresence(now: t0)
        p.observe(secondsSinceInput: 0, now: at(40))
        p.observe(secondsSinceInput: 30, now: at(50)) // a different counter, older
        XCTAssertEqual(p.lastInput, at(40))
    }

    func testInputDuringOrJustAfterAReadIsTakenForItsEcho() {
        // If a read ever shows up in the counters, it must not keep the poll going forever.
        var p = UserPresence(now: t0)
        p.readStarted(at: at(30))
        p.observe(secondsSinceInput: 0, now: at(30.2)) // mid-read
        p.readEnded(at: at(30.5))
        p.observe(secondsSinceInput: 0, now: at(31.4)) // inside the margin
        XCTAssertEqual(p.lastInput, t0, "both are the read's own echo")
        XCTAssertTrue(p.isAway(now: at(UserPresence.awayAfter)))
    }

    func testInputAfterTheMarginCounts() {
        var p = UserPresence(now: t0)
        p.readStarted(at: at(30))
        p.readEnded(at: at(30.5))
        p.observe(secondsSinceInput: 0, now: at(32))
        XCTAssertEqual(p.lastInput, at(32))
    }

    func testOnlyRecentReadsAreRemembered() {
        var p = UserPresence(now: t0)
        p.readStarted(at: at(1))
        p.readEnded(at: at(2))
        for i in 0..<20 {
            p.readStarted(at: at(10 + Double(i)))
            p.readEnded(at: at(10.1 + Double(i)))
        }
        p.observe(secondsSinceInput: 0, now: at(1.5))
        XCTAssertEqual(p.lastInput, at(1.5), "the first read has dropped out of the window list")
    }
}

final class PollPauseTests: XCTestCase {
    func testAWakeWithSomeoneThereChecksAtOnce() {
        var p = PollPause()
        XCTAssertEqual(p.didWake(awayForWakeCheck: false), .wakeCheck)
        XCTAssertFalse(p.wakeCheckDeferred)
    }

    func testAWakeWithNobodyThereWaitsForThem() {
        var p = PollPause()
        XCTAssertNil(p.didWake(awayForWakeCheck: true))
        XCTAssertNil(p.someoneMayBeBack(away: true, awayForWakeCheck: true), "still nobody")
        XCTAssertEqual(p.someoneMayBeBack(away: false, awayForWakeCheck: false), .wakeCheck)
        XCTAssertFalse(p.wakeCheckDeferred, "it runs once")
        XCTAssertNil(p.someoneMayBeBack(away: false, awayForWakeCheck: false))
    }

    func testTheLockScreenDoesNotHoldTheWakeCheck() {
        // Someone typing their password: the routine poll waits, the wake check doesn't.
        var p = PollPause()
        _ = p.didWake(awayForWakeCheck: true)
        p.didPause()
        XCTAssertEqual(p.someoneMayBeBack(away: true, awayForWakeCheck: false), .wakeCheck)
        XCTAssertFalse(p.paused)
    }

    func testATimerThatFiresAfterTheReturnRunsTheDeferredWakeCheck() {
        // The poll wasn't stopped yet, so its timer is what notices.
        var p = PollPause()
        _ = p.didWake(awayForWakeCheck: true)
        XCTAssertEqual(p.timerFired(awayForWakeCheck: true), .poll, "nobody yet: an ordinary tick, which stops at the read")
        XCTAssertTrue(p.wakeCheckDeferred)
        XCTAssertEqual(p.timerFired(awayForWakeCheck: false), .wakeCheck)
        XCTAssertEqual(p.timerFired(awayForWakeCheck: false), .poll)
    }

    func testAPausedPollResumesOnlyWhenSomeoneIsBack() {
        var p = PollPause()
        XCTAssertNil(p.someoneMayBeBack(away: false, awayForWakeCheck: false), "not paused: nothing to resume")
        p.didPause()
        XCTAssertNil(p.someoneMayBeBack(away: true, awayForWakeCheck: false), "locked: the poll still waits")
        XCTAssertEqual(p.someoneMayBeBack(away: false, awayForWakeCheck: false), .poll)
        XCTAssertFalse(p.paused)
    }

    func testSchedulingEndsThePause() {
        var p = PollPause()
        p.didPause()
        p.didSchedule()
        XCTAssertNil(p.someoneMayBeBack(away: false, awayForWakeCheck: false))
    }
}

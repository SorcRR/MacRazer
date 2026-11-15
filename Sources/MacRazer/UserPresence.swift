// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import CoreGraphics

/// Whether anyone is at the Mac, for the poll loop (#142).
///
/// Every battery read is a USB or Bluetooth transaction with the mouse, and macOS counts each
/// one as user activity: it resets the display's idle timer, so a Mac with MacRazer running
/// never slept its display. Once nobody has touched the keyboard or pointer for `awayAfter`,
/// the routine poll stops (`BatteryPollStateMachine.nextPollInterval`) and the display can
/// sleep on its own schedule. The first input after that starts it again.
///
/// "Input" comes from the window server's per-event-type counters (`CGEventSource`), not
/// `HIDIdleTime`, which the same activity tickle resets. The counters were checked to stay put
/// when user activity is declared, but nothing here can check what a given mouse's dongle does
/// on the wire. So as a second guard, input that the counters date inside one of our own
/// reads (or a moment after it) is taken for an echo of that read and ignored. A real hand
/// on the mouse is still seen at the next check after the read.
///
/// A value type with an injected clock, so the rules are unit-tested. `MouseController` keeps
/// one behind a lock: reads are recorded on its device queue, checks happen on main.
struct UserPresence {
    /// How long without keyboard or pointer input before the poll stops. The last read before
    /// that restarts the display's idle timer, so the display sleeps up to this much later
    /// than its setting says. The same as `Cadence.pointerActiveWindow`, so "in use" and
    /// "away" agree on what recent means.
    static let awayAfter: TimeInterval = 30
    /// Input dated this soon after a read ended still counts as that read's echo.
    static let echoMargin: TimeInterval = 1
    /// How many recent reads are remembered for the echo check.
    private static let windowsKept = 8

    /// When the last real input happened, as best known.
    private(set) var lastInput: Date
    /// Recent device reads, oldest first.
    private var reads: [ClosedRange<Date>] = []
    /// A read in progress, since this moment.
    private var readStartedAt: Date?
    /// When the Mac last woke from sleep. Input dated before it is ignored (`woke(at:)`).
    private var wokeAt: Date?

    /// Starts as present: the app was just launched, or just woken, by someone.
    init(now: Date) { lastInput = now }

    mutating func readStarted(at date: Date) { readStartedAt = date }

    mutating func readEnded(at date: Date) {
        let start = readStartedAt ?? date
        readStartedAt = nil
        reads.append(start...max(start, date))
        if reads.count > Self.windowsKept { reads.removeFirst(reads.count - Self.windowsKept) }
    }

    /// The Mac just woke. The counters may not count the time asleep, and then input from
    /// before the sleep reads as a moment before the wake: a Power Nap wake would look like
    /// someone at the desk. So only input dated after the wake counts from here on.
    mutating func woke(at date: Date) { wokeAt = date }

    /// Takes in the counters' answer: the most recent input was `secondsSinceInput` ago.
    mutating func observe(secondsSinceInput: TimeInterval, now: Date) {
        let input = now.addingTimeInterval(-secondsSinceInput)
        if let wokeAt, input < wokeAt { return }
        guard input > lastInput, !isEcho(input) else { return }
        lastInput = input
    }

    func isAway(now: Date) -> Bool {
        now.timeIntervalSince(lastInput) >= Self.awayAfter
    }

    private func isEcho(_ input: Date) -> Bool {
        if let readStartedAt, input >= readStartedAt { return true }
        return reads.contains { input >= $0.lowerBound && input <= $0.upperBound.addingTimeInterval(Self.echoMargin) }
    }

    /// The event types that mean a person is at the Mac. Broader than the pointer check in
    /// `MouseController.pointerIsInUse`: typing counts, and a drag sends no `mouseMoved`.
    static let inputTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel, .keyDown, .flagsChanged,
    ]

    /// Seconds since any of `inputTypes`, from the window server. No permission needed.
    static func secondsSinceInput() -> TimeInterval {
        inputTypes.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .infinity
    }
}

/// The poll loop's bookkeeping for stopping and starting again around an empty desk (#142).
/// Main thread, owned by `MouseController`, which does the timers and reads and asks this what
/// to do. A value type, so the order of wakes, ticks and returns can be unit-tested.
///
/// Two kinds of "away" come in. `away` is for routine polls: idle, screens asleep, screen
/// locked or session inactive. `awayForWakeCheck` leaves out the lock: a Mac woken to its lock
/// screen has someone typing a password with the display on, and a Bluetooth mouse should be
/// back by the time they're in. Only an idle desk or sleeping screens hold the wake check.
struct PollPause: Equatable {
    /// The poll is stopped and only the input counters are being watched.
    private(set) var paused = false
    /// The Mac woke with nobody there, and its wake check waits for someone.
    private(set) var wakeCheckDeferred = false

    enum Action: Equatable {
        /// Read the mouse now, as an ordinary poll.
        case poll
        /// Run the wake check: reads with the Bluetooth reopen cooldown lifted.
        case wakeCheck
    }

    /// The Mac woke from sleep. Nil means wait for someone.
    mutating func didWake(awayForWakeCheck: Bool) -> Action? {
        wakeCheckDeferred = awayForWakeCheck
        return awayForWakeCheck ? nil : .wakeCheck
    }

    /// The poll timer fired. A deferred wake check takes the place of the poll once someone is
    /// there. `.poll` still stops at the read if nobody is (`BatteryPollStateMachine`).
    mutating func timerFired(awayForWakeCheck: Bool) -> Action {
        guard wakeCheckDeferred, !awayForWakeCheck else { return .poll }
        wakeCheckDeferred = false
        return .wakeCheck
    }

    /// Something suggests someone may be back: the watch timer, screens waking, an unlock,
    /// the popover opening. Nil means nothing to do.
    mutating func someoneMayBeBack(away: Bool, awayForWakeCheck: Bool) -> Action? {
        if wakeCheckDeferred, !awayForWakeCheck {
            wakeCheckDeferred = false
            paused = false
            return .wakeCheck
        }
        guard paused, !away else { return nil }
        paused = false
        return .poll
    }

    mutating func didPause() { paused = true }
    mutating func didSchedule() { paused = false }
}

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
    /// How long without keyboard or pointer input before the poll stops. macOS's shortest
    /// display sleep is a minute, so with this the display sleeps at most a minute or so
    /// later than it would without MacRazer.
    static let awayAfter: TimeInterval = 60
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

    /// Starts as present: the app was just launched, or just woken, by someone.
    init(now: Date) { lastInput = now }

    mutating func readStarted(at date: Date) { readStartedAt = date }

    mutating func readEnded(at date: Date) {
        let start = readStartedAt ?? date
        readStartedAt = nil
        reads.append(start...max(start, date))
        if reads.count > Self.windowsKept { reads.removeFirst(reads.count - Self.windowsKept) }
    }

    /// Takes in the counters' answer: the most recent input was `secondsSinceInput` ago.
    mutating func observe(secondsSinceInput: TimeInterval, now: Date) {
        let input = now.addingTimeInterval(-secondsSinceInput)
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

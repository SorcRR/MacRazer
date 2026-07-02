// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The pure decision core of the battery poll loop. All the subtle connection-state logic —
/// the offline debounce, post-reconnect garbage rejection, and the charging two-poll
/// confirm — lives here as a value type with no I/O, no clock, and no queues, so it can be
/// unit-tested by replaying poll outcomes. `MouseController` performs the HID reads, feeds
/// each outcome in, and acts on the verdict.
struct BatteryPollStateMachine {
    /// Whether the most recent poll reached the device — with `batteryReady`, drives the
    /// fast/slow poll cadence.
    private(set) var lastReadOK = false
    /// True once a real battery value has been accepted; false right after a reconnect
    /// while the device is still settling. Drives fast re-polling until it's ready.
    private(set) var batteryReady = false
    private(set) var consecutiveFailures = 0
    private(set) var lastGoodPercent: Int?  // last trusted reading, for sanity-checking jumps
    private(set) var batteryRejects = 0     // implausible readings skipped since the last good one
    /// A not-charging→charging transition has been seen but not yet confirmed on a second
    /// consecutive poll.
    private(set) var pendingChargeConfirm = false

    /// What one poll's HID I/O produced.
    enum ReadOutcome {
        /// The battery level was read (raw 0-255; a refused command maps to raw 0 upstream,
        /// preserving the pre-validation behavior). `charging` is false when that secondary
        /// read failed.
        case battery(raw: UInt8, charging: Bool)
        /// Battery-less model: the alive-check passed (or was refused — link still alive).
        case aliveNoBattery
        /// Transport-level failure. `deviceGone` = no Razer device enumerated at all
        /// (vs. present-but-asleep timeouts).
        case failure(deviceGone: Bool)
    }

    enum Verdict: Equatable {
        /// Publish a real reading. `recordSample` is false for the unconfirmed first
        /// charging tick — if the report is real the sample belongs to the charge session
        /// and would skew the finished cycle's end; if it's garbage, one skipped tick is free.
        case reading(percent: Int, isCharging: Bool, recordSample: Bool)
        /// Battery-less mouse: online, no battery UI.
        case aliveNoBattery
        /// Connected, but no trustworthy value yet (raw 0 right after reconnect/wake, a
        /// refused command around sleep, or a rejected garbage jump): keep the last known
        /// percent on screen and keep polling fast.
        case notReady
        /// A failure within the debounce window — change nothing user-visible; the wireless
        /// link throws the odd transient timeout that shouldn't flap the UI or fire a sound.
        case pendingOffline
        /// Declare offline. `deviceGone` = also clear the device identity (name/id/key).
        case offline(deviceGone: Bool)
    }

    /// Digest one poll. `immediateOffline` marks an IOKit removal event — definitive, so
    /// the two-failure debounce is skipped.
    mutating func handle(_ outcome: ReadOutcome, immediateOffline: Bool = false) -> Verdict {
        switch outcome {
        case .aliveNoBattery:
            lastReadOK = true
            consecutiveFailures = 0
            batteryReady = true
            return .aliveNoBattery

        case .battery(let raw, let charging):
            lastReadOK = true
            consecutiveFailures = 0

            // A raw 0 means "connected but battery not ready yet" — common right after a
            // reconnect/wake while the dongle re-probes. Don't display a bogus 0%.
            guard raw != 0 else {
                batteryReady = false
                return .notReady
            }
            let pct = RazerCommands.batteryPercent(fromRaw: raw)

            // A reconnect/wake can return a transient garbage value (e.g. 0xFF → 100%)
            // before settling — but a wild jump is implausible at any time (a battery can't
            // swing >20% between 4-15s polls), so this check stays active even once
            // `batteryReady` is true; otherwise the very first post-reconnect read would
            // permanently disable it and a later one-off garbage read would be trusted as
            // the new baseline outright. Two rejects in a row means it isn't a blip:
            // accept the third value as the new baseline.
            if let last = lastGoodPercent, abs(pct - last) > 20, batteryRejects < 2 {
                batteryRejects += 1
                return .notReady
            }
            batteryRejects = 0
            lastGoodPercent = pct

            // Charging only counts once confirmed on a second consecutive poll — acting on
            // a false positive destructively resets the whole discharge history. Dropping
            // back to not-charging is acted on immediately, since that direction can't
            // trigger the destructive reset.
            let isCharging = charging && pendingChargeConfirm
            let skipHistoryTick = charging && !pendingChargeConfirm
            pendingChargeConfirm = charging
            batteryReady = true
            return .reading(percent: pct, isCharging: isCharging, recordSample: !skipHistoryTick)

        case .failure(let deviceGone):
            lastReadOK = false
            batteryReady = false           // force the reconnect freshness check next time
            pendingChargeConfirm = false   // a stale pending confirm must not survive a drop
            consecutiveFailures += 1
            let declareOffline = immediateOffline || consecutiveFailures >= 2
            return declareOffline ? .offline(deviceGone: deviceGone) : .pendingOffline
        }
    }

    /// A different physical unit was bound (see `ensureDevice`'s history swap): a charging
    /// debounce pending for the previous mouse must not auto-confirm the new one's first
    /// read — that's exactly the unverified-first-read case the debounce exists to guard.
    mutating func deviceChanged() {
        pendingChargeConfirm = false
    }
}

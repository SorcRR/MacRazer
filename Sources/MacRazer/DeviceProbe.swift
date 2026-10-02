// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Anything the probes can talk to. `HIDDevice` already has both calls; the tests drive the
/// probes with a scripted fake instead, so what they send and how they read the answers is
/// checked without a mouse attached.
///
/// Just the two calls the probes make, spelled exactly as `HIDDevice` spells them, so
/// conforming adds nothing to `HIDDevice` itself. Nothing model-specific: deciding per model
/// (which LED to write, say) is the caller's job.
protocol DeviceProbeChannel {
    func send(_ report: RazerReport) throws -> RazerReport
    func sendWithRetry(_ report: RazerReport, attempts: Int) throws -> RazerReport
}

extension HIDDevice: DeviceProbeChannel {}

/// The device side of the diagnostics. The CLI probes (`battery`, `dpi`, `stages`, `poll`,
/// `brightness`, `rgb`) run on these, and the in-app device test will too, so what a
/// contributor pastes from a terminal and what the app reports can never describe different
/// commands.
///
/// Each probe returns what it sent and what came back, raw response included, and leaves the
/// wording to the caller. Arguments are trusted: checking a polling rate or a stage list
/// against what the protocol accepts is the caller's job, because the right answer to bad
/// input differs between a terminal (a usage line) and the app (a control that never offers
/// it).
enum DeviceProbe {
    /// The retry count probes use: the same constant everyday traffic uses, not a copy of it.
    static let attempts = HIDDevice.defaultAttempts

    /// A value read from the mouse, with the response it was decoded from.
    struct Reading<Value> {
        let value: Value
        let response: RazerReport
    }

    /// A write followed by a read of the same setting. The acknowledgement only says the
    /// command arrived; the read-back is what says it took.
    struct WriteCheck<Value> {
        let requested: Value
        let setResponse: RazerReport
        let readBack: Reading<Value>
    }

    struct DPI: Equatable {
        let x: UInt16
        let y: UInt16
    }

    struct StageTable: Equatable {
        let stages: [Int]
        /// args[1] of the answer, as the mouse reports it.
        let activeByte: Int
    }

    /// A stage-table write and the table read back. There is no `confirmed` here, unlike
    /// `WriteCheck`: the active byte a mouse answers with need not be the index it was given.
    struct StageWrite {
        let setResponse: RazerReport
        let readBack: Reading<StageTable>
    }

    /// One LED group's answer to a brightness read. Refusals are expected, not failures: most
    /// models answer on one or two of the four groups, and which ones is the point of asking.
    struct LEDAnswer {
        let name: String
        let led: UInt8
        let result: Result<Reading<UInt8>, Error>
    }

    /// The groups the sweep asks, in order. LOGO first, since it is the one most models use.
    static let ledGroups: [(name: String, led: UInt8)] = [
        ("LOGO", Razer.logoLed), ("SCROLL", Razer.scrollLed),
        ("ZERO", Razer.zeroLed), ("BACKLIGHT", Razer.backlightLed),
    ]

    // MARK: - Battery

    /// The raw 0-255 level. args[0] of the answer is the var-store echo; the level is args[1].
    static func battery(_ channel: DeviceProbeChannel) throws -> Reading<UInt8> {
        let response = try channel.sendWithRetry(RazerCommands.getBatteryLevel(), attempts: attempts)
        return Reading(value: response.arguments[1], response: response)
    }

    // MARK: - DPI

    static func readDPI(_ channel: DeviceProbeChannel) throws -> Reading<DPI> {
        let response = try channel.sendWithRetry(RazerCommands.getDPI(), attempts: attempts)
        let parsed = RazerCommands.parseDPI(response)
        return Reading(value: DPI(x: parsed.x, y: parsed.y), response: response)
    }

    static func writeDPI(_ channel: DeviceProbeChannel, _ value: DPI) throws -> WriteCheck<DPI> {
        let set = try channel.sendWithRetry(RazerCommands.setDPI(x: value.x, y: value.y), attempts: attempts)
        return WriteCheck(requested: value, setResponse: set, readBack: try readDPI(channel))
    }

    // MARK: - DPI stages

    static func readStages(_ channel: DeviceProbeChannel) throws -> Reading<StageTable> {
        let response = try channel.sendWithRetry(RazerCommands.getDPIStages(), attempts: attempts)
        let table = StageTable(stages: RazerCommands.parseDPIStages(response),
                               activeByte: RazerCommands.parseActiveDPIStage(response))
        return Reading(value: table, response: response)
    }

    static func writeStages(_ channel: DeviceProbeChannel, stages: [Int], activeStage: Int) throws -> StageWrite {
        let set = try channel.sendWithRetry(RazerCommands.setDPIStages(stages, activeStage: activeStage),
                                            attempts: attempts)
        return StageWrite(setResponse: set, readBack: try readStages(channel))
    }

    // MARK: - Polling rate

    /// In Hz, or 0 for an answer the protocol table doesn't name.
    static func readPollingRate(_ channel: DeviceProbeChannel) throws -> Reading<Int> {
        let response = try channel.sendWithRetry(RazerCommands.getPollingRate(), attempts: attempts)
        return Reading(value: RazerCommands.parsePollingRate(response), response: response)
    }

    static func writePollingRate(_ channel: DeviceProbeChannel, hz: Int) throws -> WriteCheck<Int> {
        let set = try channel.sendWithRetry(RazerCommands.setPollingRate(hz), attempts: attempts)
        return WriteCheck(requested: hz, setResponse: set, readBack: try readPollingRate(channel))
    }

    // MARK: - Lighting

    /// Asks every LED group for its brightness, and keeps going past refusals.
    ///
    /// One attempt per group, not `attempts`: a refusal (0x03) for a given model and LED is
    /// deterministic, the same answer every time. Retrying turns a sweep on a model where three
    /// groups refuse into nine round trips and most of a second of pure backoff, in a probe
    /// whose whole job is to report which group answered.
    static func brightnessSweep(_ channel: DeviceProbeChannel) -> [LEDAnswer] {
        ledGroups.map { group in
            let result = Result {
                let response = try channel.send(RazerCommands.getBrightness(led: group.led))
                return Reading(value: response.arguments[2], response: response)
            }
            return LEDAnswer(name: group.name, led: group.led, result: result)
        }
    }

    /// Writes a raw 0-255 brightness to one group and reads it back. Unlike the sweep, a
    /// refusal here is a real failure, so it throws.
    static func writeBrightness(_ channel: DeviceProbeChannel, raw: UInt8, led: UInt8) throws -> WriteCheck<UInt8> {
        let set = try channel.sendWithRetry(RazerCommands.setBrightness(raw, led: led), attempts: attempts)
        let back = try channel.sendWithRetry(RazerCommands.getBrightness(led: led), attempts: attempts)
        return WriteCheck(requested: raw, setResponse: set,
                          readBack: Reading(value: back.arguments[2], response: back))
    }

    /// Sends a lighting effect. There is no read-back: the protocol has no command for asking
    /// which effect is showing, which is why the device test asks the person looking at it.
    static func applyLighting(_ channel: DeviceProbeChannel, _ report: RazerReport) throws -> RazerReport {
        try channel.sendWithRetry(report, attempts: attempts)
    }
}

extension DeviceProbe.WriteCheck where Value: Equatable {
    /// Whether the mouse kept what it was asked to. A mouse that clamps (a DPI above its
    /// ceiling) or quietly ignores a write reads back something else.
    var confirmed: Bool { readBack.value == requested }
}

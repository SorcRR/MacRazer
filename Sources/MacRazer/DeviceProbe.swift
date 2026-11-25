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
    struct Reading<Value: Sendable>: Sendable {
        let value: Value
        let response: RazerReport
    }

    /// A write followed by a read of the same setting. The acknowledgement only says the
    /// command arrived; the read-back is what says it took.
    struct WriteCheck<Value: Sendable>: Sendable {
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
    struct StageWrite: Sendable {
        let setResponse: RazerReport
        let readBack: Reading<StageTable>
    }

    /// One LED group's answer to a brightness read. Refusals are expected, not failures: most
    /// models answer on one or two of the four groups, and which ones is the point of asking.
    struct LEDAnswer: Sendable {
        let name: String
        let led: UInt8
        let result: Result<Reading<UInt8>, Error>
    }

    /// The groups the sweep asks, in order. LOGO first, since it is the one most models use.
    static let ledGroups: [(name: String, led: UInt8)] = [
        ("LOGO", Razer.logoLed), ("SCROLL", Razer.scrollLed),
        ("ZERO", Razer.zeroLed), ("BACKLIGHT", Razer.backlightLed),
    ]

    /// Lights the sweep doesn't ask that the lighting test also dims, on a model whose effects
    /// go there (`RazerDevices.effectLeds`). Without them the red reaches the underglow but the
    /// dim doesn't, and the person sees a light that stayed on. The Worker takes exactly these
    /// names.
    static let effectZoneGroups: [(name: String, led: UInt8)] = [
        ("UNDERGLOW", Razer.underglowLed), ("RIGHT_SIDE", Razer.rightSideLed), ("LEFT_SIDE", Razer.leftSideLed),
    ]

    /// The `effectZoneGroups` among a model's effect zones. None for a model not on record.
    static func effectZoneGroups(effectLeds: [UInt8]) -> [(name: String, led: UInt8)] {
        effectZoneGroups.filter { effectLeds.contains($0.led) }
    }

    /// The report's name for an LED: one of `ledGroups` or `effectZoneGroups`, the names the
    /// Worker takes. Hex for any other, which the Worker would turn down, so every LED a
    /// model's row names must be one of them (BasiliskV4HyperSpeedTests).
    static func groupName(led: UInt8) -> String {
        (ledGroups + effectZoneGroups).first { $0.led == led }?.name ?? String(format: "0x%02X", led)
    }

    /// One HID interface a device exposes, as the device test reports it. No location or
    /// serial: nothing here identifies a particular unit or Mac.
    struct Interface: Codable, Equatable {
        let productID: Int
        let product: String
        let usagePage: Int
        let usage: Int
        let maxFeatureReportSize: Int
        let maxInputReportSize: Int
        let transport: String
    }

    // MARK: - Identity

    static func firmware(_ channel: DeviceProbeChannel) throws -> Reading<String> {
        let response = try channel.sendWithRetry(RazerCommands.getFirmwareVersion(), attempts: attempts)
        return Reading(value: RazerCommands.parseFirmwareVersion(response), response: response)
    }

    // MARK: - Battery

    /// The raw 0-255 level. args[0] of the answer is the var-store echo; the level is args[1].
    static func battery(_ channel: DeviceProbeChannel) throws -> Reading<UInt8> {
        let response = try channel.sendWithRetry(RazerCommands.getBatteryLevel(), attempts: attempts)
        return Reading(value: response.arguments[1], response: response)
    }

    static func charging(_ channel: DeviceProbeChannel) throws -> Reading<Bool> {
        let response = try channel.sendWithRetry(RazerCommands.getChargingStatus(), attempts: attempts)
        return Reading(value: response.arguments[1] != 0, response: response)
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

    /// In Hz, or 0 for an answer the protocol table doesn't name. `usesPollingRate2` picks the
    /// newer command (`RazerDeviceInfo.usesPollingRate2`).
    static func readPollingRate(_ channel: DeviceProbeChannel, usesPollingRate2: Bool = false) throws -> Reading<Int> {
        try readPollingRate(channel, command: usesPollingRate2 ? .rate2 : .classic)
    }

    static func readPollingRate(_ channel: DeviceProbeChannel, command: PollingCommand) throws -> Reading<Int> {
        let read = RazerCommands.pollingRateRead(command: command)
        let response = try channel.sendWithRetry(read.report, attempts: attempts)
        return Reading(value: read.parse(response), response: response)
    }

    /// Sends the rate's reports, then reads it back. With polling_rate2 that's two writes, and
    /// the first one's answer is the one kept: a refusal there throws, while the second (the
    /// one OpenRazer adds) only has to leave the read-back right. That one goes once, without
    /// retries: its answer is ignored anyway, and a mouse that times out on it would otherwise
    /// cost every retry on each change. The popover writes through here too
    /// (`MouseController.sendPollingRate`), so both paths stay one.
    static func writePollingRate(_ channel: DeviceProbeChannel, hz: Int, usesPollingRate2: Bool = false) throws -> WriteCheck<Int> {
        try writePollingRate(channel, hz: hz, command: usesPollingRate2 ? .rate2 : .classic)
    }

    static func writePollingRate(_ channel: DeviceProbeChannel, hz: Int, command: PollingCommand) throws -> WriteCheck<Int> {
        let reports = RazerCommands.setPollingRateReports(hz, command: command)
        let set = try channel.sendWithRetry(reports[0], attempts: attempts)
        for report in reports.dropFirst() { _ = try? channel.sendWithRetry(report, attempts: 1) }
        return WriteCheck(requested: hz, setResponse: set,
                          readBack: try readPollingRate(channel, command: command))
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

    /// What a dock's brightness reads say about the mouse on it (`RazerDevices.lightingFollowsDockedMouse`).
    enum DockedLighting: Equatable, Sendable {
        /// These groups answered, in `dockedLightingLeds` order.
        case lit([UInt8])
        /// The mouse heard the reads and refused them all: it has no lights.
        case unlit
        /// Nothing was heard, so nothing is known. A mouse asleep on the dock does this.
        case unknown
    }

    /// The groups the dock probe asks, ZERO last. The sweep's four plus the side strips and
    /// underglow, since the dock may carry a mouse lit only there. ZERO is the all-zones id,
    /// so it counts only when nothing else answers.
    static let dockedLightingLeds: [UInt8] = [
        Razer.logoLed, Razer.scrollLed, Razer.backlightLed,
        Razer.leftSideLed, Razer.rightSideLed, Razer.underglowLed, Razer.zeroLed,
    ]

    /// Asks the mouse on a dock for each group's brightness, once each, as the sweep does.
    /// Stops at the first timeout while nothing has been heard yet, so a sleeping mouse costs
    /// one timeout, not seven. When `shouldStop` turns true (a tap is waiting) it gives up
    /// and says `.unknown`: half the answers can't tell lit from unlit.
    static func dockedLighting(_ channel: DeviceProbeChannel,
                               shouldStop: () -> Bool = { false }) -> DockedLighting {
        var answers: [(led: UInt8, result: Result<RazerReport, Error>)] = []
        for led in dockedLightingLeds {
            if shouldStop() { return .unknown }
            let result = Result { try channel.send(RazerCommands.getBrightness(led: led)) }
            answers.append((led, result))
            if case .failure(let error) = result, !isRefusal(error),
               !answers.contains(where: { isAnswer($0.result) || isHeardRefusal($0.result) }) {
                break
            }
        }
        return dockedLighting(answers)
    }

    /// The rule, apart from the reads. Any answer means lit. A refusal with no answer means
    /// unlit: the mouse heard and said no. A timeout on one group only means that group is
    /// silent, but timeouts alone say nothing.
    static func dockedLighting(_ answers: [(led: UInt8, result: Result<RazerReport, Error>)]) -> DockedLighting {
        let lit = answers.filter { isAnswer($0.result) }.map(\.led)
        if !lit.isEmpty { return .lit(lit) }
        return answers.contains(where: { isHeardRefusal($0.result) }) ? .unlit : .unknown
    }

    private static func isAnswer(_ result: Result<RazerReport, Error>) -> Bool {
        (try? result.get())?.status == RazerStatus.successful.rawValue
    }

    private static func isHeardRefusal(_ result: Result<RazerReport, Error>) -> Bool {
        if case .failure(let error) = result { return isRefusal(error) }
        return false
    }

    /// Writes a raw 0-255 brightness to one group and reads it back. Unlike the sweep, a
    /// refusal here is a real failure, so it throws. `readLed` is where the read-back goes when
    /// it isn't `led` (`RazerDeviceInfo.brightnessReadLed`).
    static func writeBrightness(_ channel: DeviceProbeChannel, raw: UInt8, led: UInt8,
                                readLed: UInt8? = nil) throws -> WriteCheck<UInt8> {
        let set = try channel.sendWithRetry(RazerCommands.setBrightness(raw, led: led), attempts: attempts)
        let back = try channel.sendWithRetry(RazerCommands.getBrightness(led: readLed ?? led), attempts: attempts)
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

extension DeviceProbe.WriteCheck where Value == DeviceProbe.DPI {
    /// `confirmed`, or for a mouse that keeps one axis (`RazerDeviceInfo.singleAxisDPI`), X
    /// as written and Y as written or 0. A Y the mouse changed to another number still fails.
    /// Strict for everything else, so a two-axis mouse that drops Y still shows it.
    func confirmed(singleAxis: Bool) -> Bool {
        guard singleAxis else { return confirmed }
        return readBack.value.x == requested.x && (readBack.value.y == requested.y || readBack.value.y == 0)
    }
}

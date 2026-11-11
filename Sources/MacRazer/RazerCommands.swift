// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Device + command constants ported from the OpenRazer Cobra Pro driver, which the
/// Cobra HyperSpeed reuses unmodified (per PR openrazer/openrazer#2583).
///
/// The per-model `transaction_id.id` byte lives in `RazerDevices` and is stamped by
/// `HIDDevice.send` — the builders here are model-agnostic.
enum Razer {
    static let vendorId: Int = 0x1532

    // Cobra HyperSpeed product IDs (PR #2583 added BOTH):
    static let pidHyperSpeedWired: Int = 0x00DA
    static let pidHyperSpeedWireless: Int = 0x00DB // user's connection mode (2.4GHz dongle)

    // Reference / template devices already in OpenRazer:
    static let pidCobra: Int = 0x00A3
    static let pidCobraProWired: Int = 0x00AF
    static let pidCobraProWireless: Int = 0x00B0

    // razercommon.h LED storage
    static let varstore: UInt8 = 0x01
    static let nostore: UInt8 = 0x00

    // LED ids (razercommon.h)
    static let backlightLed: UInt8 = 0x05
    static let logoLed: UInt8 = 0x04
    static let scrollLed: UInt8 = 0x01
    /// "All zones as one" for the effect commands — and, on no model yet seen, for
    /// brightness. Named so the `brightness` probe's sweep reads as a set of constants
    /// rather than three names and a literal.
    static let zeroLed: UInt8 = 0x00
}

/// RGB triple.
struct RGB: Codable, Equatable, Sendable {
    var r: UInt8, g: UInt8, b: UInt8
}

/// The wave effect's speed byte, `args[4]` of the wave command. Lower is faster
/// (`razerchromacommon.c`): OpenRazer always sends 0x28, and Razer's own "Fast Wave" uses 0x10.
/// The slider spans 0xC8 to 0x08. A wave's speed goes with 1 / byte, so the slider is
/// geometric: each step multiplies the byte by the same factor, and the standard 0x28
/// (200 / 40 = 40 / 8) sits exactly in the middle. Verified on the Cynosa Chroma (the
/// slider's range) and the Cobra HyperSpeed (0xC8 answered and ran slower).
enum WaveSpeed {
    static let standard: UInt8 = 0x28
    static let slowest: UInt8 = 0xC8
    static let fastest: UInt8 = 0x08

    /// The speed byte for a slider position, 0 (slowest) to 1 (fastest).
    static func byte(fromFraction fraction: Double) -> UInt8 {
        let f = max(0, min(fraction, 1))
        return UInt8((Double(slowest) * pow(Double(fastest) / Double(slowest), f)).rounded())
    }

    /// What VoiceOver says for a slider position: the slider runs 0 to 1, and a bare
    /// percentage there reads like a brightness ("0%" sounds like off).
    static func spokenValue(fromFraction fraction: Double) -> String {
        switch fraction {
        case ..<0.15: return "Slowest"
        case ..<0.4: return "Slow"
        case ..<0.6: return "Standard"
        case ..<0.85: return "Fast"
        default: return "Fastest"
        }
    }

    /// The slider position for a speed byte; bytes outside the range pin to its ends.
    static func fraction(fromByte byte: UInt8) -> Double {
        let b = Double(max(fastest, min(byte, slowest)))
        return log(Double(slowest) / b) / log(Double(slowest) / Double(fastest))
    }
}

/// Command builders — direct ports of razerchromacommon.c. The per-model transaction id is
/// stamped later by `HIDDevice.send` (see `RazerDevices.transactionId`).
enum RazerCommands {

    /// razer_chroma_misc_get_battery_level() -> get_razer_report(0x07, 0x80, 0x02)
    /// Response arguments[1] is the battery level on a 0-255 scale.
    /// Driver comment: "Returns an integer which needs to be scaled from 0-255 -> 0-100".
    /// NOTE: this is the command that TIMES OUT over the 2.4GHz dongle in the PR author's
    /// testing (dmesg command_class 07, command_id 81). Handle timeouts with backoff.
    static func getBatteryLevel() -> RazerReport {
        RazerReport(commandClass: 0x07, commandId: 0x80, dataSize: 0x02)
    }

    /// razer_chroma_standard_get_serial() -> get_razer_report(0x00, 0x82, 0x16).
    /// Response arguments hold the device's serial as an ASCII string — a stable per-unit id.
    static func getSerial() -> RazerReport {
        RazerReport(commandClass: 0x00, commandId: 0x82, dataSize: 0x16)
    }

    /// Decode a serial response into a sanitized string, or nil if blank/all-zero.
    static func parseSerial(_ resp: RazerReport) -> String? {
        let bytes = Array(resp.arguments.prefix(22)).prefix { $0 != 0 }
        let raw = String(decoding: bytes, as: UTF8.self)
        let s = raw.filter { $0.isLetter || $0.isNumber }
        guard s.count >= 4, Set(s).count > 1 else { return nil } // reject "" / "000000000000"
        return s
    }

    /// Convert a raw 0-255 battery argument byte to a 0-100 percentage.
    static func batteryPercent(fromRaw raw: UInt8) -> Int {
        Int((Double(raw) * 100.0 / 255.0).rounded())
    }

    /// razer_chroma_standard_get_firmware_version() -> get_razer_report(0x00, 0x81, 0x02).
    /// Response args[0] = major, args[1] = minor.
    static func getFirmwareVersion() -> RazerReport {
        RazerReport(commandClass: 0x00, commandId: 0x81, dataSize: 0x02)
    }

    /// "v1.3", the way OpenRazer prints it.
    static func parseFirmwareVersion(_ resp: RazerReport) -> String {
        "v\(resp.arguments[0]).\(resp.arguments[1])"
    }

    /// razer_chroma_misc_get_charging_status() — command_class 0x07, command_id 0x84
    /// (confirmed against razerchromacommon.c:1067).
    static func getChargingStatus() -> RazerReport {
        RazerReport(commandClass: 0x07, commandId: 0x84, dataSize: 0x02)
    }

    /// razer_chroma_misc_set_dpi_xy(VARSTORE, dpi_x, dpi_y)
    ///   get_razer_report(0x04, 0x05, 0x07); args: [VARSTORE, x_hi, x_lo, y_hi, y_lo, 0, 0]
    /// DPI is clamped 100..`dpiCeiling`, so ARBITRARY DPI is supported (not just the
    /// 5 marketing stages) — the UI dial can be continuous.
    static func setDPI(x: UInt16, y: UInt16) -> RazerReport {
        let dx = min(max(x, 100), UInt16(dpiCeiling))
        let dy = min(max(y, 100), UInt16(dpiCeiling))
        var r = RazerReport(commandClass: 0x04, commandId: 0x05, dataSize: 0x07)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = UInt8((dx >> 8) & 0xFF)
        r.arguments[2] = UInt8(dx & 0xFF)
        r.arguments[3] = UInt8((dy >> 8) & 0xFF)
        r.arguments[4] = UInt8(dy & 0xFF)
        return r
    }

    /// razer_chroma_misc_get_dpi_xy(VARSTORE) -> get_razer_report(0x04, 0x85, 0x07)
    /// Response mirrors the set layout: args[1..4] = x_hi, x_lo, y_hi, y_lo.
    static func getDPI() -> RazerReport {
        var r = RazerReport(commandClass: 0x04, commandId: 0x85, dataSize: 0x07)
        r.arguments[0] = Razer.varstore
        return r
    }

    /// Decode a DPI response into (x, y).
    static func parseDPI(_ resp: RazerReport) -> (x: UInt16, y: UInt16) {
        let x = (UInt16(resp.arguments[1]) << 8) | UInt16(resp.arguments[2])
        let y = (UInt16(resp.arguments[3]) << 8) | UInt16(resp.arguments[4])
        return (x, y)
    }

    /// razer_chroma_misc_get_dpi_stages(VARSTORE) -> get_razer_report(0x04, 0x86, 0x26)
    /// Response: args[1]=active stage, args[2]=count, then each stage is 7 bytes from args[3]:
    /// [stage#, x_hi, x_lo, y_hi, y_lo, 0, 0]. We read the X DPI of each. On a mouse with
    /// `RazerDeviceInfo.dpiStagesCountFromOne` the active stage and the stage numbers count
    /// from 1, as in OpenRazer: the Basilisk V4 Pro answers `01 04 05 01 01 90 … 04 0c 80 …`
    /// with its 4th stage (3200) active.
    static func getDPIStages() -> RazerReport {
        var r = RazerReport(commandClass: 0x04, commandId: 0x86, dataSize: 0x26)
        r.arguments[0] = Razer.varstore
        return r
    }

    static func parseDPIStages(_ resp: RazerReport) -> [Int] {
        let count = Int(resp.arguments[2])
        guard count > 0, count <= 7 else { return [] }
        var stages: [Int] = []
        for i in 0..<count {
            let base = 4 + i * 7 // skip stage# byte → x_hi, x_lo
            guard base + 1 < 80 else { break }
            let x = (Int(resp.arguments[base]) << 8) | Int(resp.arguments[base + 1])
            if x > 0 { stages.append(x) }
        }
        return stages
    }

    /// The active stage from a get-DPI-stages response (args[1]), as an index into
    /// `parseDPIStages`. With `countFromOne` args[1] counts from 1, and a 0 there reads as
    /// the first stage.
    static func parseActiveDPIStage(_ resp: RazerReport, countFromOne: Bool = false) -> Int {
        countFromOne ? max(0, Int(resp.arguments[1]) - 1) : Int(resp.arguments[1])
    }

    /// A stage table as the mouse reports it, with its own stage numbers. Mice number their
    /// stages from 1 in the reply, and the active byte names one of those numbers, so an edit
    /// writes the numbers back as read instead of assuming a base.
    struct DPIStageTable: Equatable {
        var activeID: UInt8
        var ids: [UInt8]
        var values: [Int]

        /// Index into `values` of the active stage, or nil when the byte names none of them.
        var activeIndex: Int? { ids.firstIndex(of: activeID) }
    }

    /// The whole table from a get-DPI-stages response, or nil when it's empty, too long, or
    /// has a zero entry (`parseDPIStages` would drop it and the indices would no longer line up).
    static func parseDPIStageTable(_ resp: RazerReport) -> DPIStageTable? {
        let count = Int(resp.arguments[2])
        guard (1...maxDPIStages).contains(count) else { return nil }
        var ids: [UInt8] = []
        var values: [Int] = []
        for i in 0..<count {
            let base = 3 + i * 7
            let x = (Int(resp.arguments[base + 1]) << 8) | Int(resp.arguments[base + 2])
            guard x > 0 else { return nil }
            ids.append(resp.arguments[base])
            values.append(x)
        }
        return DPIStageTable(activeID: resp.arguments[1], ids: ids, values: values)
    }

    /// Writes `table` back with the mouse's own stage numbers and active byte.
    static func setDPIStages(_ table: DPIStageTable) -> RazerReport {
        var r = RazerReport(commandClass: 0x04, commandId: 0x06, dataSize: 0x26)
        let count = min(table.values.count, table.ids.count, maxDPIStages)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = table.activeID
        r.arguments[2] = UInt8(count)
        for i in 0..<count {
            let dpi = UInt16(max(100, min(table.values[i], dpiCeiling)))
            let base = 3 + i * 7
            r.arguments[base] = table.ids[i]
            r.arguments[base + 1] = UInt8((dpi >> 8) & 0xFF)
            r.arguments[base + 2] = UInt8(dpi & 0xFF)
            r.arguments[base + 3] = UInt8((dpi >> 8) & 0xFF)
            r.arguments[base + 4] = UInt8(dpi & 0xFF)
        }
        return r
    }

    /// Devices store at most 5 stages (dataSize 0x26 = 3 header bytes + 5 × 7-byte records).
    static let maxDPIStages = 5

    /// The highest DPI any write sends. Each mouse's own `maxDPI` caps the slider below this;
    /// 50000 is the Basilisk V4 Pro's sensor (Focus Pro 50K), the highest of any row.
    static let dpiCeiling = 50000

    /// razer_chroma_misc_set_dpi_stages(VARSTORE, count, active_stage, dpi[])
    ///   get_razer_report(0x04, 0x06, 0x26); args: [VARSTORE, active, count,
    ///   then per stage: stage#, x_hi, x_lo, y_hi, y_lo, 0, 0]. `activeStage` is an index
    ///   into `stages` (0 = the first). The active stage and the stage numbers are written
    ///   from 0, as every mouse before the Basilisk V4 Pro was verified with, or from 1 with
    ///   `countFromOne` (`RazerDeviceInfo.dpiStagesCountFromOne`), as OpenRazer writes them:
    ///   written from 0, the V4 Pro selects the stage before the one meant.
    /// X is used for Y too — the app treats DPI as symmetric everywhere.
    static func setDPIStages(_ stages: [Int], activeStage: Int, countFromOne: Bool = false) -> RazerReport {
        var r = RazerReport(commandClass: 0x04, commandId: 0x06, dataSize: 0x26)
        let clamped = stages.prefix(maxDPIStages).map { UInt16(max(100, min($0, dpiCeiling))) }
        r.arguments[0] = Razer.varstore
        let base = countFromOne ? 1 : 0
        r.arguments[1] = UInt8(max(0, min(activeStage, clamped.count - 1)) + base)
        r.arguments[2] = UInt8(clamped.count)
        var offset = 3
        for (i, dpi) in clamped.enumerated() {
            r.arguments[offset] = UInt8(i + base) // stage number
            r.arguments[offset + 1] = UInt8((dpi >> 8) & 0xFF)
            r.arguments[offset + 2] = UInt8(dpi & 0xFF)
            r.arguments[offset + 3] = UInt8((dpi >> 8) & 0xFF)
            r.arguments[offset + 4] = UInt8(dpi & 0xFF)
            offset += 7 // two reserved bytes stay 0
        }
        return r
    }

    /// razer_chroma_misc_set_polling_rate(rate)
    ///   get_razer_report(0x00, 0x05, 0x01); arg0: 1000->0x01, 500->0x02, 125->0x08
    static func setPollingRate(_ hz: Int) -> RazerReport {
        var r = RazerReport(commandClass: 0x00, commandId: 0x05, dataSize: 0x01)
        switch hz {
        case 1000: r.arguments[0] = 0x01
        case 500:  r.arguments[0] = 0x02
        case 250:  r.arguments[0] = 0x04
        case 125:  r.arguments[0] = 0x08
        default:   r.arguments[0] = 0x02 // driver default is 500Hz
        }
        return r
    }

    /// razer_chroma_misc_get_polling_rate() -> get_razer_report(0x00, 0x85, 0x01)
    /// Response arg[0]: 0x01->1000, 0x02->500, 0x08->125.
    static func getPollingRate() -> RazerReport {
        RazerReport(commandClass: 0x00, commandId: 0x85, dataSize: 0x01)
    }

    /// Decode a poll-rate response arg[0] to Hz (0 if unrecognised).
    static func parsePollingRate(_ resp: RazerReport) -> Int {
        switch resp.arguments[0] {
        case 0x01: return 1000
        case 0x02: return 500
        // Not in OpenRazer's table, but the byte is 1000 divided by the rate, and a Pro Click V2
        // Vertical Edition left at 250 Hz answers it.
        case 0x04: return 250
        case 0x08: return 125
        default:   return 0
        }
    }

    /// Supported polling rates for this device (basic command set).
    static let supportedPollingRates = [125, 500, 1000]

    // --- Polling rate, newer command (polling_rate2) ---
    //
    // The mice that answer the classic pair with "not supported" (0x05) take this one
    // (`RazerDeviceInfo.usesPollingRate2`). Taken from fn-milans's Basilisk V4 Pro work
    // (#55), where it was written and read back on the mouse, and checked against OpenRazer's
    // razer_chroma_misc_{get,set}_polling_rate2.

    /// razer_chroma_misc_get_polling_rate2() -> get_razer_report(0x00, 0xC0, 0x01).
    /// Response arg[1] is the rate code (`pollingRate2Codes`). The Basilisk V4 Pro, V4
    /// HyperSpeed, Mouse Dock V2 Pro and DeathAdder V3 answered `00 08` (1000 Hz) in test
    /// reports, and a Viper V4 Pro on its cable `00 01` (8000 Hz).
    static func getPollingRate2() -> RazerReport {
        RazerReport(commandClass: 0x00, commandId: 0xC0, dataSize: 0x01)
    }

    /// razer_chroma_misc_set_polling_rate2(rate, argument) -> get_razer_report(0x00, 0x40, 0x02),
    /// args [argument, code]. An unknown rate falls back to 1000 Hz.
    static func setPollingRate2(_ hz: Int, argument: UInt8) -> RazerReport {
        var r = RazerReport(commandClass: 0x00, commandId: 0x40, dataSize: 0x02)
        r.arguments[0] = argument
        r.arguments[1] = pollingRate2Codes.first { $0.hz == hz }?.code ?? 0x08
        return r
    }

    /// Decode a polling_rate2 answer to Hz (0 if unrecognised).
    static func parsePollingRate2(_ resp: RazerReport) -> Int {
        pollingRate2Codes.first { $0.code == resp.arguments[1] }?.hz ?? 0
    }

    /// OpenRazer's polling_rate2 codes, one bit per rate.
    static let pollingRate2Codes: [(hz: Int, code: UInt8)] = [
        (8000, 0x01), (4000, 0x02), (2000, 0x04), (1000, 0x08), (500, 0x10), (250, 0x20), (125, 0x40),
    ]

    /// The reports that set the rate, in order. OpenRazer sends every polling_rate2 mouse the
    /// write twice, with argument 0x00 and then 0x01 ("maybe varstore"), on the cable too. The
    /// second one's status isn't what counts: the caller reads the rate back.
    static func setPollingRateReports(_ hz: Int, usesPollingRate2: Bool) -> [RazerReport] {
        usesPollingRate2
            ? [setPollingRate2(hz, argument: 0x00), setPollingRate2(hz, argument: 0x01)]
            : [setPollingRate(hz)]
    }

    /// The report that reads the rate, and how to decode its answer.
    static func pollingRateRead(usesPollingRate2: Bool) -> (report: RazerReport, parse: (RazerReport) -> Int) {
        if usesPollingRate2 { return (getPollingRate2(), parsePollingRate2) }
        return (getPollingRate(), parsePollingRate)
    }


    // --- Button function table (`OnboardButtons`): the same entries Bluetooth reaches with
    // `BLEProtocol.Key.buttonFunctionGet`. Read and written on the Basilisk V4 Pro over the
    // dongle; args [VARSTORE, entry id, 0, 7-byte block]. ---

    /// `layer` 01 reads the HyperShift layer (`parseShiftedButtonFunction`).
    static func getButtonFunction(_ id: UInt8, layer: UInt8 = 0) -> RazerReport {
        var r = RazerReport(commandClass: 0x02, commandId: 0x8C, dataSize: 0x0A)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = id
        r.arguments[2] = layer
        return r
    }

    /// `layer` 01 is the HyperShift layer (`OnboardButtons.shiftedPlan`).
    static func setButtonFunction(_ id: UInt8, block: [UInt8], layer: UInt8 = 0) -> RazerReport {
        var r = RazerReport(commandClass: 0x02, commandId: 0x0C, dataSize: 0x0A)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = id
        r.arguments[2] = layer
        for (i, byte) in block.prefix(7).enumerated() { r.arguments[3 + i] = byte }
        return r
    }

    /// The block in a `getButtonFunction` reply, or nil when the reply is for another entry.
    static func parseButtonFunction(_ resp: RazerReport, id: UInt8) -> [UInt8]? {
        guard resp.arguments[1] == id else { return nil }
        return Array(resp.arguments[3..<10])
    }

    /// A HyperShift-layer read (`getButtonFunction(_:layer: 1)`): `.set(block)` when the
    /// reply carries layer 01, `.unset` when it falls back to layer 00, which is how an entry
    /// nothing was ever written to answers (hslayerread, 2026-10-19). Nil for another entry.
    enum ShiftedFunction: Equatable { case set([UInt8]), unset }
    static func parseShiftedButtonFunction(_ resp: RazerReport, id: UInt8) -> ShiftedFunction? {
        guard resp.arguments[1] == id else { return nil }
        return resp.arguments[2] == 0x01 ? .set(Array(resp.arguments[3..<10])) : .unset
    }

    // --- Scroll wheel (Basilisk V3 family in OpenRazer; arg[0] VARSTORE, value in arg[1]) ---

    /// razer_chroma_misc_get_scroll_smart_reel() -> get_razer_report(0x02, 0x97, 0x02).
    /// The setting is args[1]; args[0] echoes the store.
    static func getScrollSmartReel() -> RazerReport { scrollRead(0x97) }

    /// razer_chroma_misc_set_scroll_smart_reel(VARSTORE, on) -> get_razer_report(0x02, 0x17, 0x02).
    /// When on, the wheel drops into free spin by itself on a fast flick.
    static func setScrollSmartReel(_ on: Bool) -> RazerReport {
        var r = RazerReport(commandClass: 0x02, commandId: 0x17, dataSize: 0x02)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = on ? 0x01 : 0x00
        return r
    }

    // --- Wheel mode on the Basilisk V4 Pro (not in OpenRazer) ---
    // Found on the mouse itself, never from Synapse: a read-only sweep of class 0x02 gets
    // before and after one press of its wheel-mode button changed exactly one answer, 0x02/0xB0.
    // Writing 0x02/0x30 (the get id minus 0x80, OpenRazer's usual get/set pairing) with
    // the owner's OK switched the wheel, read back the new value, and made the mouse send the same
    // report-5 notice (`05 39 <mode>`) its own button does. Three values: the mouse's own
    // button went 0x01 -> 0x02 in one recording and 0x02 -> 0x00 in another, and the owner felt
    // 0x00 and 0x02 as two different ratchet modes, so 0x01 is the free-spin one *(inferred)*.

    // Low-battery threshold, OpenRazer's Basilisk V3 Pro 35K command, confirmed on the V4 Pro
    // over the dongle: 0x07/0x82 reads one byte (factory 0x55), 0x07/0x02 writes it and the
    // read gives it back. The byte is on the battery level's 0-255 scale, so 0x55 is 33%.

    static func getLowBatteryThreshold() -> RazerReport {
        RazerReport(commandClass: 0x07, commandId: 0x82, dataSize: 0x01)
    }

    static func setLowBatteryThreshold(percent: Int) -> RazerReport {
        var r = RazerReport(commandClass: 0x07, commandId: 0x02, dataSize: 0x01)
        r.arguments[0] = UInt8((Double(max(0, min(percent, 100))) * 255 / 100).rounded())
        return r
    }

    static func parseLowBatteryThreshold(_ r: RazerReport) -> Int {
        Int((Double(r.arguments[0]) * 100 / 255).rounded())
    }

    /// razer_chroma_misc_get_idle_time -> 0x07/0x83, [seconds_hi, seconds_lo].
    static func getIdleTime() -> RazerReport {
        RazerReport(commandClass: 0x07, commandId: 0x83, dataSize: 0x02)
    }

    /// razer_chroma_misc_set_idle_time -> 0x07/0x03, [seconds_hi, seconds_lo]; OpenRazer
    /// accepts 60-900 seconds, the same range as the Bluetooth timer.
    static func setIdleTime(seconds: Int) -> RazerReport {
        var r = RazerReport(commandClass: 0x07, commandId: 0x03, dataSize: 0x02)
        r.arguments[0] = UInt8((seconds >> 8) & 0xFF)
        r.arguments[1] = UInt8(seconds & 0xFF)
        return r
    }

    static func parseIdleTime(_ r: RazerReport) -> Int? {
        let value = Int(r.arguments[0]) << 8 | Int(r.arguments[1])
        return BLEProtocol.sleepTimeoutRange.contains(value) ? value : nil
    }

    /// Wheel mode get: 0x02/0xB0, args [VARSTORE] -> [VARSTORE, mode].
    static func getWheelMode() -> RazerReport { scrollRead(0xB0) }

    /// Wheel mode set: 0x02/0x30, args [VARSTORE, mode].
    static func setWheelMode(_ mode: UInt8) -> RazerReport {
        var r = RazerReport(commandClass: 0x02, commandId: 0x30, dataSize: 0x02)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = mode
        return r
    }

    // --- Scroll acceleration (OpenRazer's Basilisk V3 commands; on/off in args[1]) ---

    /// razer_chroma_misc_get_scroll_acceleration() -> get_razer_report(0x02, 0x96, 0x02).
    static func getScrollAcceleration() -> RazerReport { scrollRead(0x96) }

    /// razer_chroma_misc_set_scroll_acceleration(VARSTORE, on) -> get_razer_report(0x02, 0x16, 0x02).
    static func setScrollAcceleration(_ on: Bool) -> RazerReport {
        var r = RazerReport(commandClass: 0x02, commandId: 0x16, dataSize: 0x02)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = on ? 0x01 : 0x00
        return r
    }

    // --- Wheel levels on the Basilisk V4 Pro (not in OpenRazer) ---
    // Found on the mouse itself, never from Synapse: two gets, 0x02/0xA2 and 0x02/0xA3, read
    // [VARSTORE, level], and the get id minus 0x80 writes each. Both take 0-4 and refuse 5
    // (status 0x03); factory 2. Told apart by feel, with the owner at the mouse:
    // - 0xA3 is Smart-Reel sensitivity: with Smart-Reel on, 4 dropped into free spin almost
    //   instantly and 0 needed the hardest flick.
    // - 0xA2 is the scroll acceleration level: with acceleration on, a fast spin went further
    //   at 4 than at 0.
    // Razer lists five levels for each.

    static let wheelLevelRange: ClosedRange<Int> = 0...4

    static func getSmartReelSensitivity() -> RazerReport { scrollRead(0xA3) }
    static func setSmartReelSensitivity(_ level: Int) -> RazerReport { wheelLevelWrite(0x23, level) }

    static func getScrollAccelerationLevel() -> RazerReport { scrollRead(0xA2) }
    static func setScrollAccelerationLevel(_ level: Int) -> RazerReport { wheelLevelWrite(0x22, level) }

    static func parseWheelLevel(_ r: RazerReport) -> Int? {
        let level = Int(r.arguments[1])
        return wheelLevelRange.contains(level) ? level : nil
    }

    private static func wheelLevelWrite(_ commandId: UInt8, _ level: Int) -> RazerReport {
        var r = RazerReport(commandClass: 0x02, commandId: commandId, dataSize: 0x02)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = UInt8(min(max(level, wheelLevelRange.lowerBound), wheelLevelRange.upperBound))
        return r
    }

    private static func scrollRead(_ commandId: UInt8) -> RazerReport {
        var r = RazerReport(commandClass: 0x02, commandId: commandId, dataSize: 0x02)
        r.arguments[0] = Razer.varstore
        return r
    }

    // --- Lighting (extended matrix effect command, class 0x0F / id 0x02) ---
    //
    // Cobra Pro / HyperSpeed drive ALL lighting as one group via led_id ZERO_LED (0x00).
    // The "4 zones" in Razer's marketing are NOT independently addressable in this protocol;
    // the daemon only exposes "all LEDs" + a separate "logo" (LOGO_LED 0x04) group.
    // Extended-matrix effect ids: none=0x00, static=0x01, breathing=0x02, spectrum=0x03, wave=0x04.
    static let zeroLed: UInt8 = 0x00

    /// razer_chroma_extended_matrix_effect_base(arg_size, VARSTORE, led, effect_id)
    ///   get_razer_report(0x0F, 0x02, arg_size); args[0]=store, args[1]=led, args[2]=effect
    private static func effectBase(argSize: UInt8, led: UInt8, effect: UInt8) -> RazerReport {
        var r = RazerReport(commandClass: 0x0F, commandId: 0x02, dataSize: argSize)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = led
        r.arguments[2] = effect
        return r
    }

    /// Static colour. base(0x09, …, 0x01); args[5]=0x01, args[6..8]=r,g,b.
    static func setStatic(led: UInt8 = zeroLed, rgb: RGB) -> RazerReport {
        var r = effectBase(argSize: 0x09, led: led, effect: 0x01)
        r.arguments[5] = 0x01
        r.arguments[6] = rgb.r
        r.arguments[7] = rgb.g
        r.arguments[8] = rgb.b
        return r
    }

    /// Breathing in one colour. razer_chroma_extended_matrix_effect_breathing_single:
    /// base(0x09, …, 0x02); args[3]=0x01, args[5]=0x01 (colour count), args[6..8]=r,g,b.
    /// No speed: in a hardware test, wave's speed byte in args[4] changed nothing here.
    static func setBreathingSingle(led: UInt8 = zeroLed, rgb: RGB) -> RazerReport {
        var r = effectBase(argSize: 0x09, led: led, effect: 0x02)
        r.arguments[3] = 0x01
        r.arguments[5] = 0x01
        r.arguments[6] = rgb.r
        r.arguments[7] = rgb.g
        r.arguments[8] = rgb.b
        return r
    }

    /// Breathing that alternates two colours. razer_chroma_extended_matrix_effect_breathing_dual:
    /// base(0x0C, …, 0x02); args[3]=0x02, args[5]=0x02, args[6..8]=first, args[9..11]=second.
    static func setBreathingDual(led: UInt8 = zeroLed, rgb1: RGB, rgb2: RGB) -> RazerReport {
        var r = effectBase(argSize: 0x0C, led: led, effect: 0x02)
        r.arguments[3] = 0x02
        r.arguments[5] = 0x02
        r.arguments[6] = rgb1.r
        r.arguments[7] = rgb1.g
        r.arguments[8] = rgb1.b
        r.arguments[9] = rgb2.r
        r.arguments[10] = rgb2.g
        r.arguments[11] = rgb2.b
        return r
    }

    /// Breathing in colours the mouse picks. razer_chroma_extended_matrix_effect_breathing_random:
    /// base(0x06, …, 0x02), no further arguments.
    static func setBreathingRandom(led: UInt8 = zeroLed) -> RazerReport {
        effectBase(argSize: 0x06, led: led, effect: 0x02)
    }

    /// Spectrum cycle. base(0x06, …, 0x03).
    static func setSpectrum(led: UInt8 = zeroLed) -> RazerReport {
        effectBase(argSize: 0x06, led: led, effect: 0x03)
    }

    /// Wave. base(0x06, …, 0x04); args[3]=direction (0..2), args[4]=speed (0x28 default).
    static func setWave(led: UInt8 = zeroLed, direction: UInt8 = 0x01, speed: UInt8 = WaveSpeed.standard) -> RazerReport {
        var r = effectBase(argSize: 0x06, led: led, effect: 0x04)
        r.arguments[3] = min(direction, 0x02)
        r.arguments[4] = speed
        return r
    }

    /// Off. base(0x06, …, 0x00).
    static func setNone(led: UInt8 = zeroLed) -> RazerReport {
        effectBase(argSize: 0x06, led: led, effect: 0x00)
    }

    /// The command for a `LightingEffect` on one LED group, mouse or keyboard alike.
    /// `waveSpeed` is the wave's speed byte (see `WaveSpeed`); the other effects have none.
    static func effect(_ effect: LightingEffect, color: RGB, led: UInt8 = zeroLed,
                       waveSpeed: UInt8 = WaveSpeed.standard) -> RazerReport {
        switch effect {
        case .staticColor: return setStatic(led: led, rgb: color)
        case .breathing: return setBreathingSingle(led: led, rgb: color)
        case .spectrum: return setSpectrum(led: led)
        case .wave: return setWave(led: led, speed: waveSpeed)
        case .off: return setNone(led: led)
        // A zone effect (`ZonedLighting`), never offered elsewhere: the colour alone.
        case .reactive: return setStatic(led: led, rgb: color)
        }
    }

    // --- LED brightness (extended matrix, class 0x0F) ---

    /// razer_chroma_extended_matrix_brightness(VARSTORE, led, brightness)
    ///   get_razer_report(0x0F, 0x04, 0x03); args: store, led, brightness (0–255)
    /// NOTE: brightness lives on a different LED group than the effect commands, and which
    /// group varies per model — the Cobra HyperSpeed answers only on LOGO_LED (0x04), the
    /// Basilisk V3 X HyperSpeed only on SCROLL_LED (0x01), and every other group returns
    /// status 0x03 (failure). Both verified on hardware.
    ///
    /// `led` is deliberately required rather than defaulted to the Cobra family's value: a
    /// hardcoded LOGO_LED is exactly the bug this parameter was added to fix, and it failed
    /// silently — the device refuses, nothing surfaces, the slider simply does nothing. A
    /// default would let the next call site reproduce that without a compiler error. Pass
    /// `RazerDevices.brightnessLed(pid:)`, which falls back to LOGO_LED for unknown models.
    static func setBrightness(_ value: UInt8, led: UInt8) -> RazerReport {
        var r = RazerReport(commandClass: 0x0F, commandId: 0x04, dataSize: 0x03)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = led
        r.arguments[2] = value
        return r
    }

    /// razer_chroma_extended_matrix_get_brightness(VARSTORE, LOGO_LED)
    ///   get_razer_report(0x0F, 0x84, 0x03). Response args[2] = brightness (0–255).
    static func getBrightness(led: UInt8) -> RazerReport {
        var r = RazerReport(commandClass: 0x0F, commandId: 0x84, dataSize: 0x03)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = led
        return r
    }

    static func brightnessPercent(fromRaw raw: UInt8) -> Int { Int((Double(raw) * 100 / 255).rounded()) }
    static func brightnessRaw(fromPercent pct: Int) -> UInt8 { UInt8((Double(max(0, min(pct, 100))) * 255 / 100).rounded()) }
}

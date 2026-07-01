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
}

/// RGB triple.
struct RGB: Codable, Equatable {
    var r: UInt8, g: UInt8, b: UInt8
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

    /// razer_chroma_misc_get_charging_status() — command_class 0x07, command_id 0x84
    /// (confirmed against razerchromacommon.c:1067).
    static func getChargingStatus() -> RazerReport {
        RazerReport(commandClass: 0x07, commandId: 0x84, dataSize: 0x02)
    }

    /// razer_chroma_misc_set_dpi_xy(VARSTORE, dpi_x, dpi_y)
    ///   get_razer_report(0x04, 0x05, 0x07); args: [VARSTORE, x_hi, x_lo, y_hi, y_lo, 0, 0]
    /// DPI is clamped 100..45000 in the driver, so ARBITRARY DPI is supported (not just the
    /// 5 marketing stages) — the UI dial can be continuous.
    static func setDPI(x: UInt16, y: UInt16) -> RazerReport {
        let dx = min(max(x, 100), 45000)
        let dy = min(max(y, 100), 45000)
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
    /// [stage#, x_hi, x_lo, y_hi, y_lo, 0, 0]. We read the X DPI of each.
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

    /// razer_chroma_misc_set_polling_rate(rate)
    ///   get_razer_report(0x00, 0x05, 0x01); arg0: 1000->0x01, 500->0x02, 125->0x08
    static func setPollingRate(_ hz: Int) -> RazerReport {
        var r = RazerReport(commandClass: 0x00, commandId: 0x05, dataSize: 0x01)
        switch hz {
        case 1000: r.arguments[0] = 0x01
        case 500:  r.arguments[0] = 0x02
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
        case 0x08: return 125
        default:   return 0
        }
    }

    /// Supported polling rates for this device (basic command set).
    static let supportedPollingRates = [125, 500, 1000]

    // --- Lighting (extended matrix effect command, class 0x0F / id 0x02) ---
    //
    // Cobra Pro / HyperSpeed drive ALL lighting as one group via led_id ZERO_LED (0x00).
    // The "4 zones" in Razer's marketing are NOT independently addressable in this protocol;
    // the daemon only exposes "all LEDs" + a separate "logo" (LOGO_LED 0x04) group.
    // Extended-matrix effect ids: none=0x00, static=0x01, spectrum=0x03, wave=0x04.
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

    /// Spectrum cycle. base(0x06, …, 0x03).
    static func setSpectrum(led: UInt8 = zeroLed) -> RazerReport {
        effectBase(argSize: 0x06, led: led, effect: 0x03)
    }

    /// Wave. base(0x06, …, 0x04); args[3]=direction (0..2), args[4]=speed (0x28 default).
    static func setWave(led: UInt8 = zeroLed, direction: UInt8 = 0x01, speed: UInt8 = 0x28) -> RazerReport {
        var r = effectBase(argSize: 0x06, led: led, effect: 0x04)
        r.arguments[3] = min(direction, 0x02)
        r.arguments[4] = speed
        return r
    }

    /// Off. base(0x06, …, 0x00).
    static func setNone(led: UInt8 = zeroLed) -> RazerReport {
        effectBase(argSize: 0x06, led: led, effect: 0x00)
    }

    // --- LED brightness (extended matrix, class 0x0F) ---

    /// razer_chroma_extended_matrix_brightness(VARSTORE, led, brightness)
    ///   get_razer_report(0x0F, 0x04, 0x03); args: store, led, brightness (0–255)
    /// NOTE: on the Cobra HyperSpeed brightness only works on the LOGO LED (0x04); ZERO_LED
    /// and BACKLIGHT return status 0x03 (failure). Verified on hardware.
    static func setBrightness(_ value: UInt8, led: UInt8 = Razer.logoLed) -> RazerReport {
        var r = RazerReport(commandClass: 0x0F, commandId: 0x04, dataSize: 0x03)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = led
        r.arguments[2] = value
        return r
    }

    /// razer_chroma_extended_matrix_get_brightness(VARSTORE, LOGO_LED)
    ///   get_razer_report(0x0F, 0x84, 0x03). Response args[2] = brightness (0–255).
    static func getBrightness(led: UInt8 = Razer.logoLed) -> RazerReport {
        var r = RazerReport(commandClass: 0x0F, commandId: 0x84, dataSize: 0x03)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = led
        return r
    }

    static func brightnessPercent(fromRaw raw: UInt8) -> Int { Int((Double(raw) * 100 / 255).rounded()) }
    static func brightnessRaw(fromPercent pct: Int) -> UInt8 { UInt8((Double(max(0, min(pct, 100))) * 255 / 100).rounded()) }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The separately lit parts of a mouse whose zones MacRazer sets one by one, the way Synapse
/// does. Learned on the Basilisk V4 Pro from its own replies (2026-10-19): it lists the LEDs
/// 0x04, 0x01 and 0x0A, and each answers the extended-matrix effect read with its own effect.
enum LightingZone: UInt8, CaseIterable, Identifiable, Codable, Sendable {
    case logo = 0x04
    case scrollWheel = 0x01
    case underglow = 0x0A

    var id: Self { self }

    var name: String {
        switch self {
        case .logo: return "Logo"
        case .scrollWheel: return "Wheel"
        case .underglow: return "Underglow"
        }
    }

    /// The key a profile stores the zone's lighting under.
    var storageKey: String {
        switch self {
        case .logo: return "logo"
        case .scrollWheel: return "scroll"
        case .underglow: return "underglow"
        }
    }
}

/// What one zone shows: its effect, colour and brightness.
struct ZoneLighting: Codable, Equatable, Sendable {
    /// Raw value of `LightingEffect`, as `MouseProfile.effect` keeps it.
    var effect: String
    var color: RGB
    var brightness: Int // percent

    init(effect: LightingEffect, color: RGB, brightness: Int) {
        self.effect = effect.rawValue
        self.color = color
        self.brightness = brightness
    }

    var lightingEffect: LightingEffect { LightingEffect(rawValue: effect) ?? .off }
}

/// The per-zone lighting commands. Each zone takes the extended-matrix effect command with
/// its own LED id, and the effect body that follows the LED id is the same on every link:
///
///   [effect, a, b, colours, r, g, b, r2, g2, b2]
///
///   off 00 · static 01 00 00 01 rgb · breathing 02 01 28 01 rgb · spectrum 03 00 28 00 ·
///   reactive 05 00 28 01 rgb
///
/// USB: set 0x0F/0x02 [slot, led, body], get 0x0F/0x82 [slot, led] -> [_, led, body].
/// Bluetooth: set 0x10/0x03 and get 0x10/0x83 with key [slot, led] (`BLEProtocol`).
/// The mouse also lists effect 0x08, which MacRazer doesn't offer: what it looks like isn't known.
enum ZonedLighting {
    /// The mouse's zones (`RazerDeviceInfo.lightingZones`); empty when it is lit as one.
    static func zones(pid: Int?) -> [LightingZone] { RazerDevices.lightingZones(pid: pid) }

    /// The effects these mice offer, in the picker's order.
    static let effects: [LightingEffect] = [.staticColor, .breathing, .spectrum, .reactive, .off]

    static let bodySize = 10

    static func body(_ effect: LightingEffect, color: RGB) -> [UInt8] {
        let rgb = [color.r, color.g, color.b]
        var body: [UInt8]
        switch effect {
        case .off: body = [0x00, 0, 0, 0]
        case .staticColor: body = [0x01, 0x00, 0x00, 0x01] + rgb
        case .breathing: body = [0x02, 0x01, 0x28, 0x01] + rgb
        case .spectrum: body = [0x03, 0x00, 0x28, 0x00]
        case .reactive: body = [0x05, 0x00, 0x28, 0x01] + rgb
        case .wave: body = [0x04, 0x01, 0x28, 0x00]
        }
        return body + Array(repeating: 0, count: bodySize - body.count)
    }

    /// The effect and colour in a body; nil for an effect MacRazer doesn't know. A colourless
    /// effect reports no colour.
    static func parse(_ body: ArraySlice<UInt8>) -> (effect: LightingEffect, color: RGB?)? {
        let b = Array(body)
        guard b.count >= 4 else { return nil }
        let effect: LightingEffect
        switch b[0] {
        case 0x00: effect = .off
        case 0x01: effect = .staticColor
        case 0x02: effect = .breathing
        case 0x03: effect = .spectrum
        case 0x04: effect = .wave
        case 0x05: effect = .reactive
        default: return nil
        }
        let color = b[3] >= 1 && b.count >= 7 ? RGB(r: b[4], g: b[5], b: b[6]) : nil
        return (effect, color)
    }

    static func setEffect(_ effect: LightingEffect, color: RGB, zone: LightingZone) -> RazerReport {
        var r = RazerReport(commandClass: 0x0F, commandId: 0x02, dataSize: 0x0C)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = zone.rawValue
        for (i, byte) in body(effect, color: color).enumerated() { r.arguments[2 + i] = byte }
        return r
    }

    static func getEffect(zone: LightingZone) -> RazerReport {
        var r = RazerReport(commandClass: 0x0F, commandId: 0x82, dataSize: 0x0C)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = zone.rawValue
        return r
    }

    static func parseEffect(_ resp: RazerReport) -> (effect: LightingEffect, color: RGB?)? {
        parse(resp.arguments[2..<(2 + bodySize)])
    }
}

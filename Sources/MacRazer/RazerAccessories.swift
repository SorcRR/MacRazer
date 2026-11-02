// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// What kind of accessory a row is, for its icon and the words on its card.
enum AccessoryKind: String, Equatable, Sendable {
    case keyboard
    case mousepad

    /// "Keyboard", "Mousepad".
    var label: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .mousepad: return "Mousepad"
        }
    }

    /// SF Symbol for the card's icon.
    var symbol: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mousepad: return "rectangle.inset.filled"
        }
    }
}

/// A Razer accessory (a keyboard or a mousepad) whose lighting MacRazer can set. Lighting
/// only: no keys, macros or per-key colour. Kept apart from `RazerDevices`, the mouse
/// registry, on purpose: a PID there ranks first in mouse selection, and an accessory must
/// never be taken for the mouse.
struct RazerAccessoryInfo: Equatable, Sendable {
    let pid: Int
    let name: String
    let kind: AccessoryKind
    /// Tried on real hardware. The others share a verified model's commands in OpenRazer
    /// but haven't been tried, so the card says so.
    let verified: Bool
    /// The `transaction_id.id` stamped on this model's extended-matrix commands (effects and
    /// brightness alike).
    let transactionId: UInt8
    /// The LED the effect commands name.
    let effectLed: UInt8
    /// The LED brightness is read and set on. Not always the effects' one: see the Firefly V2.
    let brightnessLed: UInt8
    /// The effects it has, in the picker's order. OpenRazer gives some pads no wave.
    var effects: [LightingEffect] = LightingEffect.allCases
    /// Effects a `verified` model hasn't been seen running yet. The card says so while one
    /// of these is picked.
    var untestedEffects: Set<LightingEffect> = []

    func supports(_ effect: LightingEffect) -> Bool { effects.contains(effect) }

    /// Seen working on this model: a verified model, and not one of its untried effects.
    func isTested(_ effect: LightingEffect) -> Bool { verified && !untestedEffects.contains(effect) }
}

enum RazerAccessories {
    /// Every row uses the extended-matrix commands (class 0x0F), the same builders the mice
    /// use, so a row is a PID, a name, a kind, a transaction id and its LEDs.
    static let known: [RazerAccessoryInfo] = [
        // Keyboards (OpenRazer `razerkbd_driver.c`): every effect and the brightness on BACKLIGHT_LED.
        //
        // Hardware-verified 2026-10-30: static, brightness, spectrum and wave all answer 0x02,
        // and the backlight changes. Its control interface reports the Mouse usage, which is
        // why mouse selection filters it out by name and by this table.
        keyboard(0x022A, "Razer Cynosa Chroma", verified: true, transactionId: 0x3F),
        keyboard(0x022C, "Razer Cynosa Chroma Pro", transactionId: 0x3F),
        keyboard(0x023F, "Razer Cynosa Lite", transactionId: 0x3F),
        // #75 (MaxL34): an Ornata V3 next to a Naga V3 Pro.
        keyboard(0x02A1, "Razer Ornata V3", transactionId: 0x1F),
        keyboard(0x028F, "Razer Ornata V3", transactionId: 0x1F),
        keyboard(0x0294, "Razer Ornata V3 X", transactionId: 0x1F),
        keyboard(0x02A2, "Razer Ornata V3 X", transactionId: 0x1F),
        keyboard(0x02A3, "Razer Ornata V3 Tenkeyless", transactionId: 0x1F),

        // Mousepads (OpenRazer `razeraccessory_driver.c`): effects on ZERO_LED.
        //
        // Firefly V2, from a user's in-app report: static colour and brightness both landed with
        // transaction id 0x1F, and brightness read back on BACKLIGHT_LED (LOGO_LED read 0).
        // OpenRazer sends 0x3F and ZERO_LED for both; what the pad answered is what's used here.
        // The other effects follow OpenRazer and haven't been seen yet. #75 (MaxL34) also has one.
        .init(pid: 0x0C04, name: "Razer Firefly V2", kind: .mousepad, verified: true, transactionId: 0x1F,
              effectLed: Razer.zeroLed, brightnessLed: Razer.backlightLed,
              untestedEffects: [.breathing, .spectrum, .wave, .off]),
        pad(0x0C08, "Razer Firefly V2 Pro"),
        // No wave in OpenRazer for the Goliathus pads.
        pad(0x0C01, "Razer Goliathus Chroma", wave: false),
        pad(0x0C02, "Razer Goliathus Chroma Extended", wave: false),
        pad(0x0C06, "Razer Goliathus Chroma 3XL", wave: false),
        // Not the original Firefly (0x0C00): OpenRazer drives it with the older standard-matrix
        // commands, which nothing here builds.
    ]

    private static func keyboard(_ pid: Int, _ name: String, verified: Bool = false,
                                 transactionId: UInt8) -> RazerAccessoryInfo {
        .init(pid: pid, name: name, kind: .keyboard, verified: verified, transactionId: transactionId,
              effectLed: Razer.backlightLed, brightnessLed: Razer.backlightLed)
    }

    /// An untested pad, exactly as OpenRazer drives it: 0x3F and ZERO_LED for everything.
    private static func pad(_ pid: Int, _ name: String, wave: Bool = true) -> RazerAccessoryInfo {
        .init(pid: pid, name: name, kind: .mousepad, verified: false, transactionId: 0x3F,
              effectLed: Razer.zeroLed, brightnessLed: Razer.zeroLed,
              effects: LightingEffect.allCases.filter { wave || $0 != .wave })
    }

    static func info(pid: Int) -> RazerAccessoryInfo? { known.first { $0.pid == pid } }

    /// The effect command for `effect` on this accessory. The same builders as the mouse's.
    static func report(for effect: LightingEffect, color: RGB, waveSpeed: UInt8 = WaveSpeed.standard,
                       on info: RazerAccessoryInfo) -> RazerReport {
        RazerCommands.effect(effect, color: color, led: info.effectLed, waveSpeed: waveSpeed)
    }

    /// Indexes into `interfaces` of the control interface of every known accessory plugged in,
    /// one per unit (PID and LocationID), ordered by LocationID and then PID so the list
    /// is stable across rescans. A unit without an interface that carries the control report
    /// is left out.
    static func controlInterfaceIndices(interfaces: [HIDInterfaceInfo]) -> [Int] {
        struct Unit: Hashable { let pid: Int; let locationID: Int }
        let units = Dictionary(grouping: interfaces.indices.filter {
            info(pid: interfaces[$0].pid) != nil
                && interfaces[$0].maxFeatureReportSize >= HIDDeviceSelection.controlReportSize
        }) { Unit(pid: interfaces[$0].pid, locationID: interfaces[$0].locationID) }
        return units
            .sorted { a, b in
                a.key.locationID != b.key.locationID ? a.key.locationID < b.key.locationID : a.key.pid < b.key.pid
            }
            .compactMap { _, members in
                members.max { HIDDeviceSelection.controlScore(interfaces[$0]) < HIDDeviceSelection.controlScore(interfaces[$1]) }
            }
    }
}

/// What an accessory was last set to from MacRazer, saved per model. The extended-matrix
/// commands can set an effect but not read one back, so this is the only record of it.
struct AccessoryLighting: Codable, Equatable, Sendable {
    /// nil until MacRazer has set one: the accessory's own effect can't be read.
    var effect: LightingEffect?
    var color: RGB
    var brightness: Int
    /// The wave's speed byte (`WaveSpeed`). Optional so lighting saved before it existed
    /// still decodes; nil is the standard speed.
    var waveSpeed: UInt8?

    static let unknown = AccessoryLighting(effect: nil, color: RGB(r: 0x44, g: 0xD6, b: 0x2C), brightness: 100)
}

extension LightingEffect: Codable {}

extension AccessoryLighting {
    /// An effect this build doesn't know (one added later) reads as nil, "never set", rather
    /// than failing the whole record and losing the colour and brightness with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        effect = (try? c.decodeIfPresent(String.self, forKey: .effect))?.flatMap(LightingEffect.init(rawValue:))
        color = try c.decode(RGB.self, forKey: .color)
        brightness = try c.decode(Int.self, forKey: .brightness)
        waveSpeed = try c.decodeIfPresent(UInt8.self, forKey: .waveSpeed)
    }
}

/// Who sets an accessory's colours while Razer Synapse is running, as the person chose.
enum AccessoryLightingOwner: String {
    case macRazer
    case synapse
}

/// Razer Synapse, if it's running. It drives the same lighting and may set its own colours
/// again on a reconnect or a wake.
enum SynapseDetector {
    /// Razer's Mac apps ship under `com.razerzone.`. The name is a fallback for a build
    /// whose bundle id doesn't follow that.
    static func isSynapse(bundleID: String?, name: String?) -> Bool {
        if let bundleID, bundleID.lowercased().hasPrefix("com.razerzone.") { return true }
        return name?.localizedCaseInsensitiveContains("Synapse") ?? false
    }
}

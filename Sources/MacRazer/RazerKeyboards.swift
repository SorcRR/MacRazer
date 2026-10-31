// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// A Razer keyboard whose backlight MacRazer can set. Lighting only: no keys, macros or
/// per-key colour. Kept apart from `RazerDevices`, the mouse registry, on purpose: a PID
/// there ranks first in mouse selection, and a keyboard must never be taken for the mouse.
struct RazerKeyboardInfo: Equatable {
    let pid: Int
    let name: String
    /// Tried on real hardware. The others share a verified model's commands in OpenRazer
    /// (`razerkbd_driver.c`) but haven't been tried, so the card says so.
    let verified: Bool
    /// The `transaction_id.id` OpenRazer stamps on this model's extended-matrix commands
    /// (effects and brightness alike): 0x3F for the Cynosa Chroma family, 0x1F for the Ornata V3.
    let transactionId: UInt8
}

enum RazerKeyboards {
    /// Every row uses the extended-matrix commands (class 0x0F) on BACKLIGHT_LED, the same
    /// builders the mice use, so a row is a PID, a name and a transaction id.
    static let known: [RazerKeyboardInfo] = [
        // Hardware-verified 2026-10-30: static, brightness, spectrum and wave all answer 0x02,
        // and the backlight changes. Its control interface reports the Mouse usage, which is
        // why mouse selection filters it out by name and by this table.
        .init(pid: 0x022A, name: "Razer Cynosa Chroma", verified: true, transactionId: 0x3F),
        .init(pid: 0x022C, name: "Razer Cynosa Chroma Pro", verified: false, transactionId: 0x3F),
        .init(pid: 0x023F, name: "Razer Cynosa Lite", verified: false, transactionId: 0x3F),
        // #75 (MaxL34): an Ornata V3 next to a Naga V3 Pro.
        .init(pid: 0x02A1, name: "Razer Ornata V3", verified: false, transactionId: 0x1F),
        .init(pid: 0x028F, name: "Razer Ornata V3", verified: false, transactionId: 0x1F),
        .init(pid: 0x0294, name: "Razer Ornata V3 X", verified: false, transactionId: 0x1F),
        .init(pid: 0x02A2, name: "Razer Ornata V3 X", verified: false, transactionId: 0x1F),
        .init(pid: 0x02A3, name: "Razer Ornata V3 Tenkeyless", verified: false, transactionId: 0x1F),
    ]

    static func info(pid: Int) -> RazerKeyboardInfo? { known.first { $0.pid == pid } }

    /// The one LED group these keyboards light: every key, as one.
    static let led = Razer.backlightLed

    /// The effect command for `effect`, on the backlight. The same builders as the mouse's.
    static func report(for effect: LightingEffect, color: RGB, waveSpeed: UInt8 = WaveSpeed.standard) -> RazerReport {
        RazerCommands.effect(effect, color: color, led: led, waveSpeed: waveSpeed)
    }

    /// Index into `interfaces` of the keyboard control interface to open, or nil when no
    /// known keyboard has one that carries the control report. With two keyboards attached
    /// the lowest LocationID wins, so the pick is stable across rescans.
    static func controlInterfaceIndex(interfaces: [HIDInterfaceInfo]) -> Int? {
        interfaces.indices
            .filter { info(pid: interfaces[$0].pid) != nil
                && interfaces[$0].maxFeatureReportSize >= HIDDeviceSelection.controlReportSize }
            .min { a, b in
                let ia = interfaces[a], ib = interfaces[b]
                if ia.locationID != ib.locationID { return ia.locationID < ib.locationID }
                return HIDDeviceSelection.controlScore(ia) > HIDDeviceSelection.controlScore(ib)
            }
    }
}

/// What the keyboard was last set to from MacRazer, saved per model. The extended-matrix
/// commands can set an effect but not read one back, so this is the only record of it.
struct KeyboardLighting: Codable, Equatable, Sendable {
    /// nil until MacRazer has set one: the keyboard's own effect can't be read.
    var effect: LightingEffect?
    var color: RGB
    var brightness: Int
    /// The wave's speed byte (`WaveSpeed`). Optional so lighting saved before it existed
    /// still decodes; nil is the standard speed.
    var waveSpeed: UInt8?

    static let unknown = KeyboardLighting(effect: nil, color: RGB(r: 0x44, g: 0xD6, b: 0x2C), brightness: 100)
}

extension LightingEffect: Codable {}

/// Who sets the keyboard's colours while Razer Synapse is running, as the person chose.
enum KeyboardLightingOwner: String {
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

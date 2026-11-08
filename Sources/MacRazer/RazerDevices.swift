// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import os

/// Which body shape `MenuBarIcon.mouseModel` draws, grouped by physical chassis rather than
/// by SKU — wired/wireless variants of the same mouse share a shape. Lives in the registry
/// (not the drawing code) so adding a mouse is a one-row change.
enum RazerMouseSilhouette {
    case cobra
    case cobraPro
    case atheris
}

/// How this PID reaches the Mac. A PID identifies the *link*, not just the mouse — wireless
/// models enumerate under a different PID when plugged in by cable — so the registry knows
/// which one each row is. Drives the "Wired"/"2.4 GHz" chip in the header; guessing it from
/// side effects (the old `charging ⇒ wired` heuristic) mislabeled every wired-only mouse as
/// "2.4 GHz", since a wired mouse never reports charging.
enum RazerConnection {
    case wired
    case wirelessDongle
    /// Razer's vendor GATT service (`BLEProtocol`). These PIDs come from the Bluetooth
    /// vendor id 0x068E, not USB's 0x1532.
    case bluetooth

    /// The link's chip wording, in the popover and the support prompt.
    var label: String {
        switch self {
        case .wired: return "Wired"
        case .wirelessDongle: return "2.4 GHz"
        case .bluetooth: return "Bluetooth"
        }
    }

    /// The chip for a model the registry doesn't know: true for both a cable and a dongle.
    static let unknownLabel = "USB"
}

/// The controls the device test checks one by one, in the order it runs them. Identify always
/// runs, and the button step is information only, so neither is here.
enum RazerFeature: String, CaseIterable {
    case battery, dpi, polling, lighting

    /// The step's name, as the test and the report spell it.
    var label: String {
        switch self {
        case .battery: return "Battery"
        case .dpi: return "DPI"
        case .polling: return "Polling rate"
        case .lighting: return "Lighting"
        }
    }
}

/// Minimal registry of Razer mice. The connected device reports its own name via the USB
/// product string, so detection works for ANY Razer mouse; this table adds per-model
/// capabilities (verified protocol, battery, lighting, max DPI), protocol quirks
/// (transaction id), and presentation (silhouette) so adding a model is one row here —
/// not edits scattered across the transport, commands, and drawing code.
///
/// To extend support to more models, port their specifics from OpenRazer
/// (daemon `mouse.py` METHODS/DPI_MAX, driver `razermouse_driver.c`) and add them here.
struct RazerDeviceInfo {
    let pid: Int
    let name: String
    /// What this link still needs a report for, in test order. Empty means fully supported.
    /// A feature listed here can still be offered in the UI (`hasLighting` decides that); this
    /// only says nobody has shown it working on hardware yet, so the device test asks for it.
    /// This is what the build shipped with. The online support list can narrow it, so ask
    /// `RazerDevices.unverified(pid:)` for what still needs a report.
    let unverified: [RazerFeature]
    var fullySupported: Bool { unverified.isEmpty }
    let hasBattery: Bool
    let hasLighting: Bool
    let maxDPI: Int
    /// The `transaction_id.id` byte OpenRazer stamps on this model's standard/misc commands
    /// (serial, DPI, polling, battery — `razermouse_driver.c`, per-PID switch in each
    /// command function). Wrong id → the firmware may ignore or NAK the command.
    let transactionId: UInt8
    /// The id for extended-matrix commands (class 0x0F: lighting effects + brightness).
    /// OpenRazer splits some models per command class — the plain Cobra uses 0xFF for misc
    /// but 0x1f for every extended-matrix command — so one id per model can't represent it.
    let matrixTransactionId: UInt8
    /// Per-command exceptions the class split can't express, keyed by
    /// `commandClass << 8 | commandId`. The Basilisk V3 uses 0x1f everywhere except the
    /// DPI-stages pair (0x04/0x06 and 0x04/0x86), which it shares with the plain Cobra's
    /// 0xFF group.
    var transactionOverrides: [UInt16: UInt8] = [:]
    /// Which LED group answers the extended-matrix *brightness* commands (class 0x0F,
    /// 0x04/0x84). Not the same id the effect commands take: the Cobra family drives
    /// effects as one group via ZERO_LED but only answers brightness on LOGO_LED, and the
    /// Basilisk V3 X HyperSpeed — whose only lit zone is the scroll wheel — answers on
    /// SCROLL_LED and returns FAILURE (0x03) for LOGO, ZERO and BACKLIGHT alike
    /// (hardware-verified via the `brightness` probe).
    /// The default is LOGO_LED, verified by the `brightness` probe on the Cobra family and on
    /// the Viper Ultimate (#6). It is an assumption on every other lit model here. A wrong id
    /// does not error, the slider just stops working, so a model gaining lighting support
    /// should be swept with `swift run MacRazer brightness` rather than inheriting this.
    var brightnessLed: UInt8 = Razer.logoLed
    /// Further lit zones that take their own brightness, written after `brightnessLed` so
    /// the slider moves the whole mouse. Reads and the write check use `brightnessLed` alone.
    /// The Nagas light the logo, scroll wheel and side panel, and all three answer.
    var extraBrightnessLeds: [UInt8] = []
    let connection: RazerConnection
    let silhouette: RazerMouseSilhouette
    /// Model key for the learned per-percent discharge curve (see `DischargeCurveModel`), or nil
    /// if this model isn't covered — its cell/firmware behavior is unverified and likely
    /// different, so it stays on the generic linear-rate estimate. Shared across every PID/
    /// serial of a covered model (one shared key) so data accumulates faster than a per-unit or
    /// per-PID table would.
    let dischargeCurveModelKey: String?
    var supportsDpiButtonBinding = false
    var supportsSleepTimeout = false
    var supportsStageEditing = false
    /// Read brightness back after setting it, and treat a mismatch as a failed write.
    var verifiesBrightnessWrite = false
    /// False for a wireless mouse that never connects by cable (the AA-cell ones), so the
    /// device test and the support prompt don't ask for a cable test it can't have.
    var hasCableLink = true
    /// False for a mouse that runs on an AA cell: it refuses the charging read every time
    /// (0x05), so the poll skips it. Not the same as `hasCableLink`: the HyperFlux V2 mat has
    /// no cable mode but charges the mouse on it.
    var canCharge = true
    /// False for a mouse whose classic polling command answers "not supported" (0x05). The
    /// HyperPolling models want OpenRazer's polling_rate2 pair, which isn't implemented, so
    /// the popover hides the picker and a profile doesn't count the write as failed.
    var acceptsClassicPolling = true
    /// True for a mouse whose light has one colour of its own (the DeathAdder Essential's is
    /// green): only brightness changes it, so the popover hides colours and effects.
    var fixedColor = false
    /// The lighting effects the firmware has, like an accessory's (`RazerAccessoryInfo.effects`).
    /// Every one by default; fewer only from OpenRazer or a report (the Basilisk Mobile has a
    /// static colour and off). The picker offers these, and any other effect (from a profile,
    /// or a mouse before) lands as the static colour.
    var effects: [LightingEffect] = LightingEffect.allCases
    /// What the mouse itself doesn't have: no battery on a wired-only mouse, no lights on an
    /// unlit one. The device test still shows that step, says so, and moves on without
    /// touching the mouse. Only from a report or the vendor spec, never from `hasBattery` or
    /// `hasLighting`, which also cover a mouse whose battery or lights the app can't drive yet.
    var notOnMouse: Set<RazerFeature> = []
    /// The model this row belongs with, when its name alone can't say: two generations that
    /// report the same name (the DeathAdder V3 Pro's) would otherwise pair one's cable with
    /// the other's dongle. Nil means the name without its link in brackets. Only for pairing
    /// rows; usage stats and the UI still use `name`.
    var model: String? = nil
}

enum RazerDevices {
    static let vendorID = 0x1532

    static let known: [RazerDeviceInfo] = [
        // 0x1f throughout: hardware-verified on the HyperSpeed (both PIDs), and what
        // OpenRazer uses for the whole Cobra Pro family.
        .init(pid: 0x00DB, name: "Razer Cobra HyperSpeed", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobraPro, dischargeCurveModelKey: "cobra-hyperspeed"),
        .init(pid: 0x00DA, name: "Razer Cobra HyperSpeed (Wired)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobraPro, dischargeCurveModelKey: "cobra-hyperspeed"),
        // Over Bluetooth (vendor 0x068E). Hardware-verified with this app: battery, serial,
        // DPI stages and brightness on LOGO_LED, the same LED as over USB. Transaction ids
        // don't apply: BLE frames carry their own request id.
        .init(pid: 0x00DC, name: "Razer Cobra HyperSpeed (Bluetooth)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .bluetooth, silhouette: .cobraPro, dischargeCurveModelKey: "cobra-hyperspeed"),
        // Basilisk V3 X HyperSpeed over Bluetooth. The shared BLE layer covers battery, DPI,
        // stages and static lighting; the DPI Cycle assignment is handled by BluetoothDevice.
        // Its only lit zone is the scroll wheel, so brightness must target SCROLL_LED.
        .init(pid: 0x00BA, name: "Razer Basilisk V3 X HyperSpeed (Bluetooth)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 18000, transactionId: 0x1f, matrixTransactionId: 0x1f, brightnessLed: Razer.scrollLed, connection: .bluetooth, silhouette: .cobra, dischargeCurveModelKey: nil, supportsDpiButtonBinding: true, supportsSleepTimeout: true, supportsStageEditing: true, verifiesBrightnessWrite: true),
        // Basilisk V3 Pro 35K over Bluetooth (two in-app reports on 0.7.0, no credit given). The
        // Bluetooth test is read-only: battery answered (99%), and so did the DPI stages read
        // (five stages from 400), sleep timeout, low battery level, button table and lighting
        // zones 0x00, 0x01, 0x04 and 0x0A over the shared BLE layer. Nobody has set DPI or
        // lighting over Bluetooth yet, so both stay unverified, lighting stays hidden as on the
        // cable, and stage editing stays off. Bluetooth has no polling command.
        .init(pid: 0x00CE, name: "Razer Basilisk V3 Pro 35K (Bluetooth)", unverified: [.dpi, .lighting], hasBattery: true, hasLighting: false, maxDPI: 35000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .bluetooth, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Basilisk V4 HyperSpeed over Bluetooth (in-app report on 0.8.0, no credit given). It
        // advertises as "BSK V4 HS". The read-only test passed battery (47%), and the DPI stages,
        // sleep timeout, low battery level and button table answered over the shared BLE layer.
        // Brightness answered on 0x0A only, and the zone effect on 0x00 and 0x0A. As with the
        // V3 Pro 35K, nobody has set DPI or lighting over Bluetooth yet, so both stay unverified
        // and lighting stays hidden, as it is on the cable. 26000 is the vendor spec.
        .init(pid: 0x00EC, name: "Razer Basilisk V4 HyperSpeed (Bluetooth)", unverified: [.dpi, .lighting], hasBattery: true, hasLighting: false, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .bluetooth, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Plain Cobra per razermouse_driver.c: 0xFF for standard/misc (serial :1509,
        // polling :2011/:2193, DPI :2600/:2781) but 0x1f for every extended-matrix
        // command (brightness :4202/:4312, spectrum :4622, static :5085, none :5301).
        // Not yet re-verified on hardware with this app.
        .init(pid: 0x00A3, name: "Razer Cobra", unverified: [], hasBattery: false, hasLighting: true, maxDPI: 8500, transactionId: 0xff, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.battery]),
        .init(pid: 0x00AF, name: "Razer Cobra Pro (Wired)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobraPro, dischargeCurveModelKey: nil),
        .init(pid: 0x00B0, name: "Razer Cobra Pro (Wireless)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobraPro, dischargeCurveModelKey: nil),
        // OpenRazer uses 0xFF for the Atheris, but 0x1f is what this app was hardware-tested
        // with (README) — verified behavior wins over the reference here.
        .init(pid: 0x0062, name: "Razer Atheris", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 7200, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .atheris, dischargeCurveModelKey: nil, hasCableLink: false, canCharge: false),
        // Basilisk V3 X HyperSpeed: AA-cell wireless (2.4 GHz dongle or Bluetooth — no
        // charging, so `is_charging` is always false). Scroll-wheel-only lighting. 0x1f
        // everywhere per razermouse_driver.c.
        //
        // Hardware-verified with this app: battery, DPI read/write, the stage table, polling
        // rate, lighting effects, and brightness on SCROLL_LED. The 18000 ceiling is the
        // vendor spec — the reporter exercised DPI at 6400, so the top of the range is the
        // one field here not demonstrated on a device.
        .init(pid: 0x00B9, name: "Razer Basilisk V3 X HyperSpeed", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 18000, transactionId: 0x1f, matrixTransactionId: 0x1f, brightnessLed: Razer.scrollLed, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, hasCableLink: false, canCharge: false),
        // Basilisk Mobile over the dongle (#83, from oss3, firmware v1.0): battery, DPI and its
        // five stages (counted from 1), polling, a static colour (on ZERO_LED, as every effect
        // is sent) and brightness on LOGO_LED all passed with 0x1f (0x3f and 0x08 answer too; 0xFF and 0x80 time out). It answers
        // the charging read, so it charges, by its USB-C cable (0x00D3, below). The firmware
        // echoed a 45000 DPI write, so the echo can't bound it: 18000 is its Focus X 18K
        // sensor's ceiling, as OpenRazer has it. OpenRazer gives it static and off only, no
        // other effects. It also connects over Bluetooth, which has no row yet.
        .init(pid: 0x00D4, name: "Razer Basilisk Mobile (Wireless)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 18000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, effects: [.staticColor, .off]),
        // Its cable, from OpenRazer's ids alone (0x00D3): nothing tried on it yet, so the device
        // test asks for every step.
        .init(pid: 0x00D3, name: "Razer Basilisk Mobile (Wired)", unverified: [.battery, .dpi, .polling, .lighting], hasBattery: true, hasLighting: true, maxDPI: 18000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, effects: [.staticColor, .off]),
        // Basilisk X HyperSpeed: the older AA-cell sibling — no lighting at all, and
        // razermouse_driver.c gives it 0xFF for every command it supports. An in-app report
        // (credit MagnetTileMan) passed battery, DPI, stages and polling with 0xFF; every
        // lighting group answers 0x05.
        .init(pid: 0x0083, name: "Razer Basilisk X HyperSpeed", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 16000, transactionId: 0xff, matrixTransactionId: 0xff, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, hasCableLink: false, canCharge: false, notOnMouse: [.lighting]),
        // Orochi V2 over the dongle (in-app report on 0.7.0, firmware v1.0, no credit given):
        // battery, DPI and stages (400 to 6400), and polling passed with 0x1f, and every id
        // answers. It runs on one AA or AAA cell, so there's no cable and no charging read. No
        // lighting: every group answers 0x05. 18000 is the vendor spec. Its Bluetooth mode has
        // no row yet.
        .init(pid: 0x00E0, name: "Razer Orochi V2", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 18000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, hasCableLink: false, canCharge: false, notOnMouse: [.lighting]),
        // Basilisk V3 on the cable (in-app report by SuperSpacer54376): DPI, the stage table,
        // polling, static color and brightness all passed. It takes 0x1f everywhere except the
        // DPI-stages pair, which answers on 0xFF as razermouse_driver.c says. Battery answers
        // 0x05, as a wired-only mouse should. LOGO and SCROLL answer brightness; ZERO and
        // BACKLIGHT return 0x03. The firmware echoed a 45000 DPI write; 26000 is its sensor's.
        .init(pid: 0x0099, name: "Razer Basilisk V3", unverified: [], hasBattery: false, hasLighting: true, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, transactionOverrides: [0x0406: 0xff, 0x0486: 0xff], extraBrightnessLeds: [Razer.scrollLed], connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.battery]),
        // Basilisk V2 (in-app report on firmware v1.4, no credit given): DPI and stages, polling
        // and lighting all passed with 0x1f, and every id answers. LOGO and SCROLL answer
        // brightness, and both dimmed and went back. The battery read answers 0x05. 20000 is the
        // vendor spec, and the top stage it shipped with.
        .init(pid: 0x0085, name: "Razer Basilisk V2", unverified: [], hasBattery: false, hasLighting: true, maxDPI: 20000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed], connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.battery]),
        // Basilisk Ultimate over its dongle (in-app report on firmware v1.6, no credit given):
        // battery, DPI and stages, and polling passed with 0x1f. LOGO and SCROLL answer
        // brightness, and the writes are acknowledged, but both read back unchanged and the
        // owner saw nothing change. Its many zones may need another command, so lighting
        // stays hidden and unverified. 20000 is the vendor spec. The cable (0x0086) has no row.
        .init(pid: 0x0088, name: "Razer Basilisk Ultimate (Wireless)", unverified: [.lighting], hasBattery: true, hasLighting: false, maxDPI: 20000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Naga Hex V2 (in-app report on firmware v1.0, credited to foivos92): DPI and polling
        // passed with 0x1f. It has no battery: the read answers with zeros. Every LED group
        // answers brightness with 0 and ignores writes: OpenRazer drives this model with the
        // older standard-matrix commands, which nothing here builds, so lighting stays hidden
        // and unverified, as on the Naga Chroma. The stage table read returns 0x03, so the
        // popover shows no stages. 16000 is the vendor spec; it took 45000 without clamping.
        .init(pid: 0x0050, name: "Razer Naga Hex V2", unverified: [.lighting], hasBattery: false, hasLighting: false, maxDPI: 16000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.battery]),
        // DeathAdder Essential (two in-app reports, no credit given): wired only, battery 0x05.
        // DPI, the stage table and polling passed with 0x1f (every id answers on the cable);
        // it ships at 125 Hz. Its one light is green only (vendor spec): brightness on LOGO
        // dims it, but no color can show, so one run saw no red. That is the most it can do,
        // so lighting counts as verified rather than asking every owner for a test that can't
        // pass. 6400 is the vendor spec.
        .init(pid: 0x0098, name: "Razer DeathAdder Essential", unverified: [], hasBattery: false, hasLighting: true, maxDPI: 6400, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, fixedColor: true, notOnMouse: [.battery]),
        // The older DeathAdder Essential and its White Edition (no reports yet): wired only,
        // 6400 DPI. razermouse_driver.c gives them 0xFF for DPI and polling. Their light uses
        // the older single-LED commands, not the extended matrix this app sends, so no
        // lighting here until someone tries it. The 2018 one reports the same product string
        // as the 0x0098 row; its name here says the year so the two read apart in lists.
        // Nothing matches rows by name across the same link, so the difference is harmless,
        // but tell them apart by product id, not by name.
        .init(pid: 0x006E, name: "Razer DeathAdder Essential (2018)", unverified: [.dpi, .polling], hasBattery: false, hasLighting: false, maxDPI: 6400, transactionId: 0xff, matrixTransactionId: 0xff, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.battery]),
        .init(pid: 0x0071, name: "Razer DeathAdder Essential White Edition", unverified: [.dpi, .polling], hasBattery: false, hasLighting: false, maxDPI: 6400, transactionId: 0xff, matrixTransactionId: 0xff, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.battery]),
        // Orochi2013
        .init(pid: 0x0039, name: "Razer Orochi 2013", unverified: [.polling], hasBattery: false, hasLighting: false, maxDPI: 6400, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Viper Ultimate (Wireless)
        .init(pid: 0x007b, name: "Razer Viper Ultimate (Wireless)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 20000, transactionId: 0xff, matrixTransactionId: 0x3f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Viper Ultimate (Wired): an in-app report over the cable passed battery, DPI, polling
        // and lighting with the same ids as the wireless side.
        .init(pid: 0x007a, name: "Razer Viper Ultimate (Wired)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 20000, transactionId: 0xff, matrixTransactionId: 0x3f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Pro Click V2 Vertical Edition on the cable (#35, from k6n7frbrtc-hub): battery and a
        // static color (status 0x02, the mouse visibly changed) worked with 0x1f. DPI, polling
        // and brightness weren't tried here. OpenRazer drives its brightness, static, spectrum
        // and wave on ZERO_LED, but breathing on BACKLIGHT_LED, which this app doesn't do per
        // effect yet: lighting stays unverified until a device test shows what answers. 30000
        // DPI is the vendor spec (Focus Pro 30K sensor). ZERO_LED for brightness is OpenRazer's
        // word only, so a write is read back and a refusal shows. Its HyperSpeed dongle
        // (0x00C8) has no row: every read over it timed out, and a known row would rank it with
        // working mice when choosing which device to open. It's still this model
        // (`unlistedModels`), so the counts take cable and dongle for one mouse.
        .init(pid: 0x00C7, name: "Razer Pro Click V2 Vertical Edition (Wired)", unverified: [.dpi, .polling, .lighting], hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, brightnessLed: Razer.zeroLed, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, verifiesBrightnessWrite: true, model: RazerDevices.proClickV2Vertical),
        // Naga Pro over the dongle (#69): battery, DPI and stages, polling, static color and
        // brightness all passed the in-app test with 0x1f. 0xFF and 0x80 time out. It has
        // three lit zones and LOGO, SCROLL and BACKLIGHT all answer brightness (ZERO refuses),
        // so the slider writes all three.
        .init(pid: 0x0090, name: "Razer Naga Pro (Wireless)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 20000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed, Razer.backlightLed], connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Naga Pro on the cable (in-app report on firmware v2.2, no credit given): battery, DPI
        // and stages, polling, static color and brightness all passed with 0x1f, and every id
        // answers. LOGO, SCROLL and BACKLIGHT answer brightness, as over the dongle.
        .init(pid: 0x008F, name: "Razer Naga Pro (Wired)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 20000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed, Razer.backlightLed], connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Naga V3 Pro over the dongle (#33, report from chris-agnew): battery, DPI and stages,
        // polling, static color and brightness all passed with 0x1f. 0xFF and 0x80 time out.
        // Same three-zone lighting as the Naga Pro, so the slider writes all three. The
        // firmware echoed a 45000 DPI write; 30000 is the vendor spec.
        .init(pid: 0x00E8, name: "Razer Naga V3 Pro (Wireless)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed, Razer.backlightLed], connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Naga V3 Pro on the cable (two in-app reports, one from chris-agnew): every test passed
        // with 0x1f, the same zones as the dongle. Its control interface is the second one.
        .init(pid: 0x00E7, name: "Razer Naga V3 Pro (Wired)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed, Razer.backlightLed], connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Naga Trinity (in-app report, no credit given): wired only, so no battery (0x05).
        // DPI, polling, static color and brightness passed with 0x1f. LOGO and SCROLL answer
        // brightness, ZERO and BACKLIGHT return 0x03. 16000 is OpenRazer's DPI_MAX. A second
        // report from another owner saw neither the dim nor the red, though every write
        // succeeded; kept verified until a third report says which one is right.
        .init(pid: 0x0067, name: "Razer Naga Trinity", unverified: [], hasBattery: false, hasLighting: true, maxDPI: 16000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed], connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.battery]),
        // Naga Chroma (in-app report, no credit given): an older wired-only Naga. DPI and
        // polling passed with 0x1f. Its battery read answers zeros. The extended-matrix
        // brightness commands are acknowledged but every zone reads back 0 and nothing
        // changes, so it likely takes the older standard-matrix (class 0x03) lighting
        // commands. Lighting stays off until those are tried. The DPI stages read fails (0x03).
        .init(pid: 0x0053, name: "Razer Naga Chroma", unverified: [.lighting], hasBattery: false, hasLighting: false, maxDPI: 16000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.battery]),
        // Mouse Dock Pro: the dock acts as the receiver for the mouse paired to it, so what
        // answers is that mouse. The one report (no credit given) had a Naga V3 Pro behind
        // it: battery, DPI, static color and brightness passed with 0x1f. The classic polling
        // command answers "not supported" (0x05). Brightness stays on LOGO_LED alone, since
        // other mice the dock pairs with may lack the Naga's side panel. The dock's own
        // lighting is not reachable here.
        .init(pid: 0x00A4, name: "Razer Mouse Dock Pro", unverified: [.polling], hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, acceptsClassicPolling: false),
        // HyperFlux V2 charging mat: like the Mouse Dock Pro, the mat is the receiver for the
        // mouse on it, so what answers is that mouse. The one report (no credit given) passed
        // battery, DPI and stages, and polling with 0x1f. 0x80 times out, and 0xFF answers with
        // a different firmware (v1.0.16, likely the mat itself) and times out on every lighting
        // read, so 0xFF reaches another device than 0x1f does. The mouse behind it
        // has a tilt wheel and answers Smart Reel, but the report doesn't name it. LOGO and
        // SCROLL answer brightness and the static red showed. A second report, on 0.8.0 with
        // mat firmware v2.50, passed everything again and confirmed the lights went dark and
        // then red, so lighting is verified too. It also read charging as on, which is why
        // `canCharge` stays true here. Brightness stays on LOGO_LED alone, as on the dock.
        // The firmware echoed a 45000 DPI write; 30000 matches the dock's row.
        // The mat has no cable mode for the mouse, so no cable link is asked about.
        .init(pid: 0x00CF, name: "Razer HyperFlux V2", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, hasCableLink: false),
        // Basilisk V4 HyperSpeed over the dongle (in-app report, no credit given): battery and
        // DPI answered with 0x1f. 0xFF and 0x80 time out. Every LED group refuses brightness,
        // so no lighting. The classic polling command answers "not supported" (0x05); it likely
        // needs OpenRazer's polling_rate2 pair, as the V4 Pro does in #55. Until that is tried,
        // the popover hides the polling picker and the row stays unverified. The 26000 DPI
        // ceiling is the app's default for unknown models, not a measured value. The name has
        // no "(Wireless)": usage stats count models by it, and 0.6 already sent it this way.
        .init(pid: 0x00EA, name: "Razer Basilisk V4 HyperSpeed", unverified: [.polling], hasBattery: true, hasLighting: false, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, acceptsClassicPolling: false),
        // Basilisk V4 Pro over the dongle (in-app report, no credit given): battery, DPI and
        // stages, static color and brightness passed with 0x1f. LOGO and SCROLL answer
        // brightness, ZERO and BACKLIGHT return 0x03. The classic polling command answers
        // "not supported" (0x05), the same gap as the V4 HyperSpeed, so the row stays
        // unverified. 35000 is the vendor spec (its Focus Pro 35K sensor).
        .init(pid: 0x00E3, name: "Razer Basilisk V4 Pro (Wireless)", unverified: [.polling], hasBattery: true, hasLighting: true, maxDPI: 35000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed], connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, acceptsClassicPolling: false),
        // Basilisk V4 Pro on the cable (in-app report on firmware v1.1 from by_hlz): battery,
        // DPI and stages, static color and brightness passed with 0x1f, and every id answers.
        // LOGO and SCROLL answer brightness. The classic polling command answers 0x05, as over
        // the dongle. Its control interface is the fourth one. Same 35000 ceiling as the dongle.
        .init(pid: 0x00E2, name: "Razer Basilisk V4 Pro (Wired)", unverified: [.polling], hasBattery: true, hasLighting: true, maxDPI: 35000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed], connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, acceptsClassicPolling: false),
        // DeathAdder V3 HyperSpeed over the dongle (in-app report, no credit given): DPI and
        // stages and polling passed with 0x1f. It has no lighting (every group answers 0x05).
        // The battery read timed out in the first report and in a 0.7.0 run on firmware v1.10,
        // then answered with 0x1f in a 0.7.0 run on v1.2. The timeouts look like the mouse
        // sleeping, but a v1.10 quirk isn't ruled out.
        .init(pid: 0x00C5, name: "Razer DeathAdder V3 HyperSpeed", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.lighting]),
        // DeathAdder V3 HyperSpeed on the cable (two in-app reports, one credited to fxaxg):
        // battery, DPI and stages, and polling passed with 0x1f on firmware v1.10 and v1.2.
        // Every lighting group answers 0x05, as over the dongle. The name has no "(Wired)",
        // to match the dongle row and what the mouse reports, so usage stats count it as one
        // model. modelName still pairs the two rows by name.
        .init(pid: 0x00C4, name: "Razer DeathAdder V3 HyperSpeed", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.lighting]),
        // DeathAdder V2 Pro over the dongle (in-app report, no credit given): battery answered
        // with 0x1f (0x3f and 0x08 answer too; 0xFF and 0x80 time out). A 0.7.0 report then
        // passed DPI, polling and lighting. Only LOGO answers brightness; the rest return
        // 0x03. 20000 is the vendor spec.
        .init(pid: 0x007D, name: "Razer DeathAdder V2 Pro (Wireless)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 20000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil),
        // DeathAdder V2 Pro on the cable (in-app report on firmware v2.1, no credit given):
        // battery (charging), DPI and stages, and polling passed with 0x1f. Only LOGO answers
        // brightness, as over the dongle. Taking it to 0 worked, but every command after that
        // failed at the USB level, the restore included, so the logo may have been left dark.
        // Until a second report shows lighting is safe on the cable, it stays hidden here.
        .init(pid: 0x007C, name: "Razer DeathAdder V2 Pro (Wired)", unverified: [.lighting], hasBattery: true, hasLighting: false, maxDPI: 20000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Viper V3 HyperSpeed over the dongle (in-app report, no credit given): battery, DPI and
        // stages, and polling all passed with 0x1f (0x3f and 0x08 answer too; 0xFF and 0x80 time
        // out). It has no lighting: every group answers 0x05. The firmware echoed a 45000 DPI
        // write, so the echo can't bound it: 26000 is the ceiling of its Focus X 26K sensor. It
        // runs on an AA cell, so it has no cable mode to ask about.
        .init(pid: 0x00B8, name: "Razer Viper V3 HyperSpeed", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, hasCableLink: false, canCharge: false, notOnMouse: [.lighting]),
        // Viper V4 Pro on the cable (in-app report, no credit given): battery and DPI and stages
        // passed with 0x1f (every id tried answers on the cable). It has no lighting: every group
        // answers 0x05. The classic polling command answers "not supported" (0x05), as on the
        // Basilisk V4 models, so it likely needs the polling_rate2 pair and the row stays
        // unverified. Its control interface is the fourth one. Its sensor is the Focus Pro 50K,
        // but 45000 is as high as the app writes (the driver's clamp), and the firmware echoed it.
        .init(pid: 0x00E5, name: "Razer Viper V4 Pro (Wired)", unverified: [.polling], hasBattery: true, hasLighting: false, maxDPI: 45000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, acceptsClassicPolling: false, notOnMouse: [.lighting]),
        // Viper V4 Pro over the dongle (in-app report from Robotxm): battery and DPI and stages
        // passed with 0x1f, and every id tried answers. No lighting (every group answers 0x05),
        // and the classic polling command answers 0x05, as on its cable. Same 45000 ceiling.
        .init(pid: 0x00E6, name: "Razer Viper V4 Pro (Wireless)", unverified: [.polling], hasBattery: true, hasLighting: false, maxDPI: 45000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, acceptsClassicPolling: false, notOnMouse: [.lighting]),
        // Basilisk V4 HyperSpeed on the cable (two in-app reports, no credit given): battery and
        // DPI and stages passed with 0x1f, and every id answers. As over the dongle, every LED
        // group refuses brightness and the classic polling command answers 0x05. Its control
        // interface is the fourth one. The owner found 2 of its 4 thumb buttons and one wheel
        // tilt unusable for remapping: the tilt sends horizontal scroll (consumer page 0x238),
        // and the other two thumb buttons sent nothing standard during the button step.
        .init(pid: 0x00EB, name: "Razer Basilisk V4 HyperSpeed (Wired)", unverified: [.polling], hasBattery: true, hasLighting: false, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, acceptsClassicPolling: false),
        // Pro Click V2 over the dongle (in-app report, no credit given): battery, DPI and stages,
        // and polling passed with 0x1f. 0xFF and 0x80 time out. No lighting (every group
        // returns 0x03). 30000 is the vendor spec, as for the Vertical Edition.
        .init(pid: 0x00D1, name: "Razer Pro Click V2", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.lighting]),
        // Pro Click over the dongle and on the cable (in-app reports on firmware v1.2, no credit
        // given): battery, DPI and stages, and polling passed with 0x1f, and every id answers.
        // No lighting: every group answers 0x05. The firmware echoed a 45000 DPI write; 16000
        // is the vendor spec. Both rows carry the name the mouse reports, so usage stats count
        // it as one model.
        .init(pid: 0x0077, name: "Razer Pro Click", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 16000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.lighting]),
        .init(pid: 0x0080, name: "Razer Pro Click", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 16000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.lighting]),
        // Viper (in-app report on firmware v1.3, no credit given): a wired-only mouse. DPI and
        // stages, polling, static color and brightness passed with 0x1f, and every id answers.
        // The battery read answers 0x05. Only LOGO answers brightness. 16000 is the vendor
        // spec. The owner found the two left side buttons not detected for remapping.
        .init(pid: 0x0078, name: "Razer Viper", unverified: [], hasBattery: false, hasLighting: true, maxDPI: 16000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.battery]),
        // DeathAdder V3 Pro over its first dongle (in-app report on firmware v2.1, no credit
        // given): battery, DPI and stages, and polling passed with 0x1f. 0xFF and 0x80 time
        // out. No lighting: every group returns 0x03. It also answers the polling_rate2 read,
        // but the classic command works. 30000 is the vendor spec. The later generation reports
        // the same name, so each row names its model to keep one's cable from pairing with the
        // other's dongle.
        .init(pid: 0x00B7, name: "Razer DeathAdder V3 Pro", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.lighting], model: RazerDevices.deathAdderV3Pro),
        // Its cable (in-app report on firmware v2.2, no credit given): battery (charging), DPI,
        // and polling passed with 0x1f, and every id answers. No lighting: every group returns
        // 0x03. It holds a single DPI stage, and took a 45000 write without clamping.
        .init(pid: 0x00B6, name: "Razer DeathAdder V3 Pro", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.lighting], model: RazerDevices.deathAdderV3Pro),
        // DeathAdder V3 Pro over its later dongle (in-app report on firmware v2.0, no credit
        // given): the same results as the first one. Its cable (0x00C2) has no row yet.
        .init(pid: 0x00C3, name: "Razer DeathAdder V3 Pro", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.lighting], model: RazerDevices.deathAdderV3ProLater),
        // Viper V3 Pro SE over the dongle (in-app report on firmware v1.0, no credit given):
        // battery, DPI and stages, and polling passed with 0x1f. 0xFF and 0x80 time out. No
        // lighting: every group answers 0x05. 35000 is the vendor spec. Its cable has no row.
        .init(pid: 0x00DF, name: "Razer Viper V3 Pro SE", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 35000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.lighting]),
        // Viper 8KHz (in-app report on firmware v1.0, no credit given): a wired-only mouse.
        // DPI and stages, static color and brightness passed with 0x1f, and every id answers.
        // Only LOGO answers brightness. The battery read answers 0x05. The classic polling
        // command answers 0x05 too, while the polling_rate2 read answers, so like the Basilisk
        // V4 models it needs that pair and polling stays unverified. 20000 is the vendor spec.
        .init(pid: 0x0091, name: "Razer Viper 8KHz", unverified: [.polling], hasBattery: false, hasLighting: true, maxDPI: 20000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, acceptsClassicPolling: false, notOnMouse: [.battery]),
        // Naga V2 HyperSpeed over the dongle (two in-app reports on firmware v1.1, no credit
        // given): battery, DPI and stages, and polling passed with 0x1f. 0xFF and 0x80 time out.
        // No lighting: every group answers 0x05. The charging read answers 0x05 too: it runs on
        // an AA cell, so it has no cable mode to ask about. 30000 is the vendor spec.
        .init(pid: 0x00B4, name: "Razer Naga V2 HyperSpeed", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, hasCableLink: false, canCharge: false, notOnMouse: [.lighting]),
        // Naga V2 Pro on the cable (in-app report, no credit given): battery, DPI and stages,
        // polling, static color and brightness all passed with 0x1f, and every id answers.
        // LOGO and BACKLIGHT answer brightness (SCROLL and ZERO return 0x03), so the slider
        // writes both. 30000 is the vendor spec.
        .init(pid: 0x00A7, name: "Razer Naga V2 Pro (Wired)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.backlightLed], connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Taipan (in-app report, no credit given): an older wired-only mouse. DPI and polling
        // passed with 0x1f, and every id answers. The battery read returns 0x03. Every LED group
        // refuses the extended-matrix commands, so its light likely takes the older single-LED
        // ones; no lighting here until someone tries them, and lighting stays unverified so a
        // report can say. The DPI stages read fails (0x03).
        // 8200 is its sensor's ceiling and the DPI it reported. The owner found only the two
        // left side buttons detected for remapping, of six extra buttons.
        .init(pid: 0x0034, name: "Razer Taipan", unverified: [.lighting], hasBattery: false, hasLighting: false, maxDPI: 8200, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, notOnMouse: [.battery]),
        // Basilisk V3 Pro 35K on the cable (in-app report, no credit given): battery, DPI and
        // stages, and polling passed with 0x1f. LOGO and SCROLL answer brightness and every
        // lighting write is acknowledged, but the owner saw neither the dim nor the red, so the
        // lighting controls stay hidden until a report shows them working. Both zones are
        // recorded for the slider for when they are. 35000 is the spec.
        .init(pid: 0x00CC, name: "Razer Basilisk V3 Pro 35K (Wired)", unverified: [.lighting], hasBattery: true, hasLighting: false, maxDPI: 35000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed], connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
    ]

    static func info(pid: Int) -> RazerDeviceInfo? { known.first { $0.pid == pid } }
    /// Product ids reachable over Bluetooth, which `HIDDevice.bluetoothControlDevice()`
    /// looks for before anything touches CoreBluetooth.
    static var bluetoothPIDs: Set<Int> { Set(known.filter { $0.connection == .bluetooth }.map(\.pid)) }
    /// Model names that work over Bluetooth, for user-facing text ("Razer Cobra HyperSpeed").
    /// Only fully supported rows: a Bluetooth row with only its battery confirmed isn't one
    /// to send people to Bluetooth for.
    static var bluetoothModelNames: [String] {
        known.filter { $0.connection == .bluetooth && fullySupported($0) }
            .map { $0.name.replacingOccurrences(of: " (Bluetooth)", with: "") }
    }
    static func fullySupported(pid: Int) -> Bool { info(pid: pid).map(fullySupported(_:)) ?? false }
    /// A row's name without the link in brackets: "Razer Naga Pro (Wired)" is "Razer Naga Pro".
    static func modelName(_ name: String) -> String {
        name.replacingOccurrences(of: #" \((Wired|Wireless|Bluetooth)\)$"#, with: "", options: .regularExpression)
    }
    /// Each row's `modelName`, worked out once: the popover asks on every redraw.
    private static let modelNames: [Int: String] = Dictionary(
        known.map { ($0.pid, $0.model ?? modelName($0.name)) }, uniquingKeysWith: { first, _ in first })
    private static func modelName(of row: RazerDeviceInfo) -> String {
        modelNames[row.pid] ?? row.model ?? modelName(row.name)
    }
    /// The model of a product id with no row yet: whose name another generation shares, from
    /// OpenRazer's ids (the DeathAdder V3 Pro's later cable), or whose link doesn't answer yet
    /// (the Pro Click V2 Vertical Edition's dongle).
    private static let unlistedModels: [Int: String] = [
        0x00C2: deathAdderV3ProLater,
        // The Pro Click V2 Vertical Edition's dongle (#35), which nothing answers on yet.
        0x00C8: proClickV2Vertical,
    ]
    static let deathAdderV3Pro = "Razer DeathAdder V3 Pro"
    static let deathAdderV3ProLater = "Razer DeathAdder V3 Pro (later)"
    static let proClickV2Vertical = "Razer Pro Click V2 Vertical Edition"
    /// An unlisted mouse's model from its name, or nil when generations share the name, so it
    /// can't say which one the mouse is.
    private static func unlistedModel(named name: String) -> String? {
        let model = modelName(name)
        return known.contains { $0.model != nil && modelName($0.name) == model } ? nil : model
    }
    /// The model `pid` belongs to, whatever its link: the registry's row, or a known product id
    /// with no row yet (the DeathAdder V3 Pro's cables). Nil for one the registry can't place,
    /// so two generations that share a name never pass for one mouse.
    static func model(pid: Int) -> String? {
        info(pid: pid).map(modelName(of:)) ?? unlistedModels[pid]
    }

    /// Whether the registry fully supports the model `pid` is on another link, `connection`:
    /// a row with the same model name on that link. False when `pid` isn't known.
    static func fullySupported(modelOf pid: Int, on connection: RazerConnection) -> Bool {
        guard let name = info(pid: pid).map(modelName(of:)) else { return false }
        return known.contains { $0.connection == connection && fullySupported($0) && modelName(of: $0) == name }
    }
    /// What the row for `pid` still needs a report for, or nil when the model isn't known.
    static func unverified(pid: Int) -> [RazerFeature]? { info(pid: pid).map(unverified(_:)) }

    // MARK: - The online support list

    /// Posted on the main thread when the online support list changes what a row still needs.
    static let supportChanged = Notification.Name("RazerDevices.supportChanged")
    /// Per pid, the features the online support list still has as unverified. Only rows it
    /// covers and that passed `SupportList`'s checks are here. It can only narrow a row,
    /// never add to it, and nothing that talks to the mouse reads it: transaction ids, LEDs,
    /// DPI and the rest always come from the row as built. Locked, since the HID side asks
    /// for rows off the main thread.
    private static let narrowed = OSAllocatedUnfairLock<[Int: Set<RazerFeature>]>(initialState: [:])

    /// Replaces what the online support list says. Call on the main thread; observers of
    /// `supportChanged` update there.
    static func applySupportList(_ remaining: [Int: Set<RazerFeature>]) {
        let changed = narrowed.withLock { current in
            defer { current = remaining }
            return current != remaining
        }
        if changed { NotificationCenter.default.post(name: supportChanged, object: nil) }
    }

    /// What `row` still needs: its own list, less what the online list has confirmed since,
    /// in the row's test order.
    private static func unverified(_ row: RazerDeviceInfo) -> [RazerFeature] {
        guard let remaining = narrowed.withLock({ $0[row.pid] }) else { return row.unverified }
        return row.unverified.filter(remaining.contains)
    }
    private static func fullySupported(_ row: RazerDeviceInfo) -> Bool { unverified(row).isEmpty }
    /// What has been shown working on `pid`'s link: the features the row has, less those still
    /// unverified. Lighting counts when it is unverified, even with the controls hidden, since
    /// the mouse has it and the test is what would turn it on.
    static func verified(pid: Int) -> [RazerFeature] {
        guard let info = info(pid: pid) else { return [] }
        return verified(info, missing: unverified(info))
    }
    private static func verified(_ info: RazerDeviceInfo, missing: [RazerFeature]) -> [RazerFeature] {
        RazerFeature.allCases.filter { feature in
            switch feature {
            case .battery where !info.hasBattery, .lighting where !info.hasLighting: return false
            // Bluetooth has no polling command, so it never counts as working there.
            case .polling where info.connection == .bluetooth: return false
            default: return !missing.contains(feature)
            }
        }
    }

    /// How far the registry supports one link of a mouse.
    enum LinkSupport: Equatable {
        /// Every control is verified on this link.
        case full
        /// Some controls are verified and some aren't, so a test can ask for just those.
        case partly(works: [RazerFeature], missing: [RazerFeature])
        /// Not on record, or on record with nothing shown working yet.
        case unknown
    }

    static func support(pid: Int) -> LinkSupport {
        guard let info = info(pid: pid) else { return .unknown }
        return support(info, missing: unverified(info))
    }
    private static func support(_ info: RazerDeviceInfo, missing: [RazerFeature]) -> LinkSupport {
        if missing.isEmpty { return .full }
        let works = verified(info, missing: missing)
        return works.isEmpty ? .unknown : .partly(works: works, missing: missing)
    }

    /// What a report would do for one link of a mouse, worked out once from one read of the
    /// support list: the support prompt, its popover card and the device test all go by it.
    struct LinkAsk: Equatable {
        let support: LinkSupport
        /// Still unverified on this link, and a test on it can confirm it (`askable`).
        let here: [RazerFeature]
        /// Still unverified on this link, but only another link's test can confirm it: over
        /// Bluetooth, whatever the read-only test would have to set.
        let elsewhere: [RazerFeature]
        /// The model's other links still worth a report.
        let links: [LinkToTest]
        /// Not on record: everything is worth a test.
        let unknownModel: Bool
        /// A test here can teach nothing new: fully supported, or all it lacks needs another link.
        var nothingToRunHere: Bool { !unknownModel && here.isEmpty }
        /// Whether a report would still help, here or on another link. What the prompt asks about.
        var needsReport: Bool { unknownModel || !here.isEmpty || !links.isEmpty }
    }

    static func ask(pid: Int) -> LinkAsk {
        guard let info = info(pid: pid) else {
            return LinkAsk(support: .unknown, here: [], elsewhere: [], links: [], unknownModel: true)
        }
        let missing = unverified(info)
        let testable = testable(missing, of: info)
        let here = askable(testable, on: info.connection)
        return LinkAsk(support: support(info, missing: missing), here: here,
                       elsewhere: testable.filter { !here.contains($0) },
                       links: linksToTest(besides: pid), unknownModel: false)
    }

    /// Whether a report would still teach us something about this mouse: on this link, or on
    /// another way the same model connects. What the support prompt asks about.
    static func needsReport(pid: Int) -> Bool { ask(pid: pid).needsReport }

    /// What any report could confirm out of `row`'s `missing`. Polling is left out on a row
    /// whose mouse refuses the classic command: the test only sends that one, so a run would
    /// record the same refusal again (as the device test's own `missingFeatures` already
    /// knows). Without this the prompt kept asking Basilisk V4 and Viper 8KHz owners for a
    /// test that couldn't answer it.
    private static func testable(_ missing: [RazerFeature], of row: RazerDeviceInfo) -> [RazerFeature] {
        row.acceptsClassicPolling ? missing : missing.filter { $0 != .polling }
    }

    /// What a report from `link` could confirm out of `missing`. The Bluetooth test only reads,
    /// so there it can confirm the battery and nothing it would have to set.
    static func askable(_ missing: [RazerFeature], on link: RazerConnection) -> [RazerFeature] {
        link == .bluetooth ? missing.filter { $0 == .battery } : missing
    }

    /// Whether the app may change `pid`'s DPI. Over USB an unverified DPI is still offered, as
    /// the README says. Over Bluetooth it isn't: the Bluetooth test can't show it working, so
    /// a model whose DPI nobody has set there only shows its stages.
    static func writesDPI(pid: Int) -> Bool {
        guard let info = info(pid: pid), info.connection == .bluetooth else { return true }
        return !unverified(info).contains(.dpi)
    }

    /// The other rows of a model whose only ask was a test on `connection`: fully supported
    /// themselves, with `connection` among their links to test. A report from that link
    /// answers them. `name` is the tested mouse's own name, for a product id not on record.
    static func rowsAnswered(byReportFrom pid: Int, name: String, on connection: RazerConnection) -> [Int] {
        guard let model = model(pid: pid) ?? unlistedModel(named: name)
        else { return [] }
        return known.filter {
            $0.pid != pid && modelName(of: $0) == model && fullySupported($0)
                && linksToTest(besides: $0.pid).contains { $0.connection == connection }
        }.map(\.pid)
    }

    /// Another way the same model connects that is still worth a report.
    struct LinkToTest: Equatable {
        let connection: RazerConnection
        /// What that link's row still needs, or nil when the registry has no row for it.
        let missing: [RazerFeature]?
    }

    /// The other links of `pid`'s model worth testing. A link with a row is worth it when the
    /// row isn't fully supported. Bluetooth is only ever suggested from a row: nothing else
    /// says the mouse has it. A cable or dongle without a row is suggested for a mouse with a
    /// battery on the other USB link, since a wired-only mouse has no dongle, unless the row
    /// says it has no cable mode. Otherwise whether it has a cable is unknown, so the wording
    /// has to allow for "it doesn't".
    static func linksToTest(besides pid: Int) -> [LinkToTest] {
        guard let info = info(pid: pid) else { return [] }
        let model = modelName(of: info)
        let siblings = known.filter { $0.pid != pid && modelName(of: $0) == model }
        var links: [LinkToTest] = []
        for link in [RazerConnection.wired, .wirelessDongle, .bluetooth] where link != info.connection {
            if let row = siblings.first(where: { $0.connection == link }) {
                let missing = askable(testable(unverified(row), of: row), on: link)
                if !missing.isEmpty { links.append(.init(connection: link, missing: missing)) }
            } else if link != .bluetooth, info.connection != .bluetooth, info.hasBattery,
                      link != .wired || info.hasCableLink {
                links.append(.init(connection: link, missing: nil))
            }
        }
        return links
    }

    /// Defaults assume a full-featured mouse for unknown models (so we still attempt controls).
    static func hasBattery(pid: Int) -> Bool { info(pid: pid)?.hasBattery ?? true }
    static func hasLighting(pid: Int) -> Bool { info(pid: pid)?.hasLighting ?? true }
    /// False for an AA-cell mouse, which has nothing to charge.
    static func canCharge(pid: Int) -> Bool { info(pid: pid)?.canCharge ?? true }
    static func maxDPI(pid: Int) -> Int { info(pid: pid)?.maxDPI ?? 26000 }
    static func supportsDpiButtonBinding(pid: Int) -> Bool { info(pid: pid)?.supportsDpiButtonBinding ?? false }
    static func supportsSleepTimeout(pid: Int) -> Bool { info(pid: pid)?.supportsSleepTimeout ?? false }
    static func supportsStageEditing(pid: Int) -> Bool { info(pid: pid)?.supportsStageEditing ?? false }
    /// Editing a stage over the dongle or cable: any USB row whose DPI is verified. The stage
    /// write itself isn't covered by the device test yet, so the controller reads the table
    /// back after every write and reports a mismatch.
    static func supportsUSBStageEditing(pid: Int) -> Bool {
        guard let info = info(pid: pid) else { return false }
        return info.connection != .bluetooth && !info.unverified.contains(.dpi)
    }
    static func verifiesBrightnessWrite(pid: Int) -> Bool { info(pid: pid)?.verifiesBrightnessWrite ?? false }
    static func acceptsClassicPolling(pid: Int) -> Bool { info(pid: pid)?.acceptsClassicPolling ?? true }
    static func fixedColor(pid: Int) -> Bool { info(pid: pid)?.fixedColor ?? false }
    static func effects(pid: Int) -> [LightingEffect] { info(pid: pid)?.effects ?? LightingEffect.allCases }
    /// Empty for a model not on record: the test is how anyone finds out.
    static func notOnMouse(pid: Int) -> Set<RazerFeature> { info(pid: pid)?.notOnMouse ?? [] }
    /// Per-command transaction id: explicit per-command override, else the class split
    /// (see `RazerDeviceInfo.matrixTransactionId`). 0x1f default for unknown models — the
    /// Cobra-family id this app has hardware verified.
    static func transactionId(pid: Int, commandClass: UInt8, commandId: UInt8) -> UInt8 {
        guard let info = info(pid: pid) else { return 0x1f }
        if let override = info.transactionOverrides[UInt16(commandClass) << 8 | UInt16(commandId)] {
            return override
        }
        return commandClass == 0x0F ? info.matrixTransactionId : info.transactionId
    }

    /// nil for unknown models — the UI then shows a neutral "USB" chip, which is true for
    /// both a cable and a dongle.
    static func connection(pid: Int?) -> RazerConnection? {
        pid.flatMap { info(pid: $0)?.connection }
    }
    /// Whether `wired` is the cable of the same model `dongle` is the dongle of: two rows of
    /// one mouse, so with both plugged in the cable is the one to use. It carries everything,
    /// and with the cable in, the dongle has nothing to add.
    static func isCable(_ wired: Int, ofDongle dongle: Int) -> Bool {
        guard let cable = info(pid: wired), let receiver = info(pid: dongle),
              cable.connection == .wired, receiver.connection == .wirelessDongle else { return false }
        return modelName(of: cable) == modelName(of: receiver)
    }
    static func silhouette(pid: Int?) -> RazerMouseSilhouette { pid.flatMap { info(pid: $0)?.silhouette } ?? .cobra }
    static func dischargeCurveModelKey(pid: Int) -> String? { info(pid: pid)?.dischargeCurveModelKey }
    /// LED group for brightness get/set. Unknown models fall back to LOGO_LED, the id the
    /// Cobra family answers on.
    static func brightnessLed(pid: Int?) -> UInt8 {
        pid.flatMap { info(pid: $0)?.brightnessLed } ?? Razer.logoLed
    }
    /// Every LED group a brightness write goes to, `brightnessLed` first.
    static func brightnessLeds(pid: Int?) -> [UInt8] {
        [brightnessLed(pid: pid)] + (pid.flatMap { info(pid: $0)?.extraBrightnessLeds } ?? [])
    }
}

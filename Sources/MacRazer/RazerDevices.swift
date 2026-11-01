// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

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
    /// False for a mouse whose classic polling command answers "not supported" (0x05). The
    /// HyperPolling models want OpenRazer's polling_rate2 pair, which isn't implemented, so
    /// the popover hides the picker and a profile doesn't count the write as failed.
    var acceptsClassicPolling = true
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
        // Plain Cobra per razermouse_driver.c: 0xFF for standard/misc (serial :1509,
        // polling :2011/:2193, DPI :2600/:2781) but 0x1f for every extended-matrix
        // command (brightness :4202/:4312, spectrum :4622, static :5085, none :5301).
        // Not yet re-verified on hardware with this app.
        .init(pid: 0x00A3, name: "Razer Cobra", unverified: [], hasBattery: false, hasLighting: true, maxDPI: 8500, transactionId: 0xff, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        .init(pid: 0x00AF, name: "Razer Cobra Pro (Wired)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobraPro, dischargeCurveModelKey: nil),
        .init(pid: 0x00B0, name: "Razer Cobra Pro (Wireless)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobraPro, dischargeCurveModelKey: nil),
        // OpenRazer uses 0xFF for the Atheris, but 0x1f is what this app was hardware-tested
        // with (README) — verified behavior wins over the reference here.
        .init(pid: 0x0062, name: "Razer Atheris", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 7200, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .atheris, dischargeCurveModelKey: nil, hasCableLink: false),
        // Basilisk V3 X HyperSpeed: AA-cell wireless (2.4 GHz dongle or Bluetooth — no
        // charging, so `is_charging` is always false). Scroll-wheel-only lighting. 0x1f
        // everywhere per razermouse_driver.c.
        //
        // Hardware-verified with this app: battery, DPI read/write, the stage table, polling
        // rate, lighting effects, and brightness on SCROLL_LED. The 18000 ceiling is the
        // vendor spec — the reporter exercised DPI at 6400, so the top of the range is the
        // one field here not demonstrated on a device.
        .init(pid: 0x00B9, name: "Razer Basilisk V3 X HyperSpeed", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 18000, transactionId: 0x1f, matrixTransactionId: 0x1f, brightnessLed: Razer.scrollLed, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, hasCableLink: false),
        // Basilisk X HyperSpeed: the older AA-cell sibling — no lighting at all, and
        // razermouse_driver.c gives it 0xFF for every command it supports. Not verified
        // on hardware by us.
        .init(pid: 0x0083, name: "Razer Basilisk X HyperSpeed", unverified: [.battery, .dpi, .polling], hasBattery: true, hasLighting: false, maxDPI: 16000, transactionId: 0xff, matrixTransactionId: 0xff, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, hasCableLink: false),
        // Basilisk V3 on the cable (in-app report by SuperSpacer54376): DPI, the stage table,
        // polling, static color and brightness all passed. It takes 0x1f everywhere except the
        // DPI-stages pair, which answers on 0xFF as razermouse_driver.c says. Battery answers
        // 0x05, as a wired-only mouse should. LOGO and SCROLL answer brightness; ZERO and
        // BACKLIGHT return 0x03. The firmware echoed a 45000 DPI write; 26000 is its sensor's.
        .init(pid: 0x0099, name: "Razer Basilisk V3", unverified: [], hasBattery: false, hasLighting: true, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, transactionOverrides: [0x0406: 0xff, 0x0486: 0xff], extraBrightnessLeds: [Razer.scrollLed], connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // DeathAdder Essential (two in-app reports, no credit given): wired only, battery 0x05.
        // DPI, the stage table and polling passed with 0x1f (every id answers on the cable);
        // it ships at 125 Hz. Its one light is green only (vendor spec): brightness on LOGO
        // dims it, but no color can show, so one run saw no red. That is the most it can do,
        // so lighting counts as verified rather than asking every owner for a test that can't
        // pass. 6400 is the vendor spec.
        .init(pid: 0x0098, name: "Razer DeathAdder Essential", unverified: [], hasBattery: false, hasLighting: true, maxDPI: 6400, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Orochi2013
        .init(pid: 0x0039, name: "Razer Orochi 2013", unverified: [.polling], hasBattery: false, hasLighting: false, maxDPI: 6400, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Viper Ultimate (Wireless)
        .init(pid: 0x007b, name: "Razer Viper Ultimate (Wireless)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 20000, transactionId: 0xff, matrixTransactionId: 0x3f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Viper Ultimate (Wired)
        .init(pid: 0x007a, name: "Razer Viper Ultimate (Wired)", unverified: [.battery, .dpi, .polling, .lighting], hasBattery: true, hasLighting: true, maxDPI: 20000, transactionId: 0xff, matrixTransactionId: 0x3f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Naga Pro over the dongle (#69): battery, DPI and stages, polling, static color and
        // brightness all passed the in-app test with 0x1f. 0xFF and 0x80 time out. It has
        // three lit zones and LOGO, SCROLL and BACKLIGHT all answer brightness (ZERO refuses),
        // so the slider writes all three.
        .init(pid: 0x0090, name: "Razer Naga Pro (Wireless)", unverified: [], hasBattery: true, hasLighting: true, maxDPI: 20000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed, Razer.backlightLed], connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Naga Pro on the cable: same ids as the dongle per razermouse_driver.c. Not verified.
        .init(pid: 0x008F, name: "Razer Naga Pro (Wired)", unverified: [.battery, .dpi, .polling, .lighting], hasBattery: true, hasLighting: true, maxDPI: 20000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed, Razer.backlightLed], connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
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
        .init(pid: 0x0067, name: "Razer Naga Trinity", unverified: [], hasBattery: false, hasLighting: true, maxDPI: 16000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed], connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Naga Chroma (in-app report, no credit given): an older wired-only Naga. DPI and
        // polling passed with 0x1f. Its battery read answers zeros. The extended-matrix
        // brightness commands are acknowledged but every zone reads back 0 and nothing
        // changes, so it likely takes the older standard-matrix (class 0x03) lighting
        // commands. Lighting stays off until those are tried. The DPI stages read fails (0x03).
        .init(pid: 0x0053, name: "Razer Naga Chroma", unverified: [.lighting], hasBattery: false, hasLighting: false, maxDPI: 16000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Mouse Dock Pro: the dock acts as the receiver for the mouse paired to it, so what
        // answers is that mouse. The one report (no credit given) had a Naga V3 Pro behind
        // it: battery, DPI, static color and brightness passed with 0x1f. The classic polling
        // command answers "not supported" (0x05). Brightness stays on LOGO_LED alone, since
        // other mice the dock pairs with may lack the Naga's side panel. The dock's own
        // lighting is not reachable here.
        .init(pid: 0x00A4, name: "Razer Mouse Dock Pro", unverified: [.polling], hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, acceptsClassicPolling: false),
        // Basilisk V4 HyperSpeed over the dongle (in-app report, no credit given): battery and
        // DPI answered with 0x1f. 0xFF and 0x80 time out. Every LED group refuses brightness,
        // so no lighting. The classic polling command answers "not supported" (0x05); it likely
        // needs OpenRazer's polling_rate2 pair, as the V4 Pro does in #55. Until that is tried,
        // the polling picker fails here, so the row stays unverified. The 26000 DPI ceiling is
        // the app's default for unknown models, not a measured value.
        .init(pid: 0x00EA, name: "Razer Basilisk V4 HyperSpeed", unverified: [.polling], hasBattery: true, hasLighting: false, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, acceptsClassicPolling: false),
        // Basilisk V4 Pro over the dongle (in-app report, no credit given): battery, DPI and
        // stages, static color and brightness passed with 0x1f. LOGO and SCROLL answer
        // brightness, ZERO and BACKLIGHT return 0x03. The classic polling command answers
        // "not supported" (0x05), the same gap as the V4 HyperSpeed, so the row stays
        // unverified. The 26000 ceiling is the app's default, not a measured value.
        .init(pid: 0x00E3, name: "Razer Basilisk V4 Pro (Wireless)", unverified: [.polling], hasBattery: true, hasLighting: true, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, extraBrightnessLeds: [Razer.scrollLed], connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, acceptsClassicPolling: false),
        // DeathAdder V3 HyperSpeed over the dongle (in-app report, no credit given): DPI and
        // stages and polling passed with 0x1f. It has no lighting (every group answers 0x05).
        // The battery read timed out, so the row stays unverified until it answers.
        .init(pid: 0x00C5, name: "Razer DeathAdder V3 HyperSpeed", unverified: [.battery], hasBattery: true, hasLighting: false, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil),
        // DeathAdder V2 Pro over the dongle (in-app report, no credit given): battery answered
        // with 0x1f (0x3f and 0x08 answer too; 0xFF and 0x80 time out). DPI, polling and
        // lighting were skipped, so the row stays unverified. Only LOGO answers brightness;
        // the rest return 0x03. 20000 is the vendor spec.
        .init(pid: 0x007D, name: "Razer DeathAdder V2 Pro (Wireless)", unverified: [.dpi, .polling, .lighting], hasBattery: true, hasLighting: true, maxDPI: 20000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Viper V3 HyperSpeed over the dongle (in-app report, no credit given): battery, DPI and
        // stages, and polling all passed with 0x1f (0x3f and 0x08 answer too; 0xFF and 0x80 time
        // out). It has no lighting: every group answers 0x05. The firmware echoed a 45000 DPI
        // write, so the echo can't bound it: 26000 is the ceiling of its Focus X 26K sensor. It
        // runs on an AA cell, so it has no cable mode to ask about.
        .init(pid: 0x00B8, name: "Razer Viper V3 HyperSpeed", unverified: [], hasBattery: true, hasLighting: false, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, hasCableLink: false),
        // Viper V4 Pro on the cable (in-app report, no credit given): battery and DPI and stages
        // passed with 0x1f (every id tried answers on the cable). It has no lighting: every group
        // answers 0x05. The classic polling command answers "not supported" (0x05), as on the
        // Basilisk V4 models, so it likely needs the polling_rate2 pair and the row stays
        // unverified. Its control interface is the fourth one. Its sensor is the Focus Pro 50K,
        // but 45000 is as high as the app writes (the driver's clamp), and the firmware echoed it.
        .init(pid: 0x00E5, name: "Razer Viper V4 Pro (Wired)", unverified: [.polling], hasBattery: true, hasLighting: false, maxDPI: 45000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, acceptsClassicPolling: false),
    ]

    static func info(pid: Int) -> RazerDeviceInfo? { known.first { $0.pid == pid } }
    /// Product ids reachable over Bluetooth, which `HIDDevice.bluetoothControlDevice()`
    /// looks for before anything touches CoreBluetooth.
    static var bluetoothPIDs: Set<Int> { Set(known.filter { $0.connection == .bluetooth }.map(\.pid)) }
    /// Model names that work over Bluetooth, for user-facing text ("Razer Cobra HyperSpeed").
    static var bluetoothModelNames: [String] {
        known.filter { $0.connection == .bluetooth }
            .map { $0.name.replacingOccurrences(of: " (Bluetooth)", with: "") }
    }
    static func fullySupported(pid: Int) -> Bool { info(pid: pid)?.fullySupported ?? false }
    /// A row's name without the link in brackets: "Razer Naga Pro (Wired)" is "Razer Naga Pro".
    static func modelName(_ name: String) -> String {
        name.replacingOccurrences(of: #" \((Wired|Wireless|Bluetooth)\)$"#, with: "", options: .regularExpression)
    }
    /// Each row's `modelName`, worked out once: the popover asks on every redraw.
    private static let modelNames: [Int: String] = Dictionary(
        known.map { ($0.pid, modelName($0.name)) }, uniquingKeysWith: { first, _ in first })
    private static func modelName(of row: RazerDeviceInfo) -> String { modelNames[row.pid] ?? modelName(row.name) }
    /// Whether the registry fully supports the model `pid` is on another link, `connection`:
    /// a row with the same model name on that link. False when `pid` isn't known.
    static func fullySupported(modelOf pid: Int, on connection: RazerConnection) -> Bool {
        guard let name = info(pid: pid).map(modelName(of:)) else { return false }
        return known.contains { $0.connection == connection && $0.fullySupported && modelName(of: $0) == name }
    }
    /// What the row for `pid` still needs a report for, or nil when the model isn't known.
    static func unverified(pid: Int) -> [RazerFeature]? { info(pid: pid)?.unverified }
    /// What has been shown working on `pid`'s link: the features the row has, less those still
    /// unverified. Lighting counts when it is unverified, even with the controls hidden, since
    /// the mouse has it and the test is what would turn it on.
    static func verified(pid: Int) -> [RazerFeature] {
        guard let info = info(pid: pid) else { return [] }
        return RazerFeature.allCases.filter { feature in
            switch feature {
            case .battery where !info.hasBattery, .lighting where !info.hasLighting: return false
            default: return !info.unverified.contains(feature)
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
        guard let missing = unverified(pid: pid) else { return .unknown }
        if missing.isEmpty { return .full }
        let works = verified(pid: pid)
        return works.isEmpty ? .unknown : .partly(works: works, missing: missing)
    }

    /// Whether a report would still teach us something about this mouse: on this link, or on
    /// another way the same model connects. What the support prompt asks about.
    static func needsReport(pid: Int) -> Bool {
        support(pid: pid) != .full || !linksToTest(besides: pid).isEmpty
    }

    /// The other rows of a model whose only ask was a test on `connection`: fully supported
    /// themselves, with `connection` among their links to test. A report from that link
    /// answers them. `name` is the tested mouse's own name, for a product id not on record.
    static func rowsAnswered(byReportFrom pid: Int, name: String, on connection: RazerConnection) -> [Int] {
        let model = info(pid: pid).map(modelName(of:)) ?? modelName(name)
        return known.filter {
            $0.pid != pid && modelName(of: $0) == model && $0.fullySupported
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
                if !row.fullySupported { links.append(.init(connection: link, missing: row.unverified)) }
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
    static func maxDPI(pid: Int) -> Int { info(pid: pid)?.maxDPI ?? 26000 }
    static func supportsDpiButtonBinding(pid: Int) -> Bool { info(pid: pid)?.supportsDpiButtonBinding ?? false }
    static func supportsSleepTimeout(pid: Int) -> Bool { info(pid: pid)?.supportsSleepTimeout ?? false }
    static func supportsStageEditing(pid: Int) -> Bool { info(pid: pid)?.supportsStageEditing ?? false }
    static func verifiesBrightnessWrite(pid: Int) -> Bool { info(pid: pid)?.verifiesBrightnessWrite ?? false }
    static func acceptsClassicPolling(pid: Int) -> Bool { info(pid: pid)?.acceptsClassicPolling ?? true }
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

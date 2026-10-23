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
    let fullySupported: Bool
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
    let connection: RazerConnection
    let silhouette: RazerMouseSilhouette
    /// Model key for the learned per-percent discharge curve (see `DischargeCurveModel`), or nil
    /// if this model isn't covered — its cell/firmware behavior is unverified and likely
    /// different, so it stays on the generic linear-rate estimate. Shared across every PID/
    /// serial of a covered model (one shared key) so data accumulates faster than a per-unit or
    /// per-PID table would.
    let dischargeCurveModelKey: String?
    var supportsDpiButtonBinding = false
    /// The mouse's own sleep timer: `BLEProtocol.Key.powerTimeoutGet` on a Bluetooth row,
    /// `RazerCommands.getIdleTime` (0x07/0x83) on a cable or dongle row.
    var supportsSleepTimeout = false
    var supportsStageEditing = false
    /// Read brightness back after setting it, and treat a mismatch as a failed write.
    var verifiesBrightnessWrite = false

    // Capabilities of mice that keep their settings in the mouse (the Basilisk V4 Pro is the
    // first). Each one is off by default, so a row that doesn't set it behaves as before.

    /// Polling through OpenRazer's polling_rate2 pair (0x00/0xC0, 0x00/0x40, up to 8000 Hz)
    /// instead of 0x00/0x85 and 0x00/0x05 (`RazerCommands.setPollingRateReports`). USB only.
    var usesPollingRate2 = false
    /// Wheel mode (0x02/0xB0, 0x02/0x30) and Smart-Reel (0x02/0x97, 0x02/0x17). USB only.
    var hasWheelControls = false
    /// How readily Smart-Reel drops into free spin, five levels (0x02/0xA3, 0x02/0x23). USB only.
    var hasSmartReelSensitivity = false
    /// Scroll acceleration on/off (0x02/0x96, 0x02/0x16) and its level, five steps
    /// (0x02/0xA2, 0x02/0x22). USB only.
    var hasScrollAcceleration = false
    /// The battery level the mouse goes into low-battery mode at (0x07/0x82, 0x07/0x02;
    /// `BLEProtocol.Key.lowBatteryGet` over Bluetooth).
    var supportsLowBatteryThreshold = false
    /// Onboard profile slots (`OnboardSlots`): every settings command goes to the active slot.
    var hasOnboardSlots = false
    /// The popover's Single and Stages DPI modes: DPI is set through the stage table on
    /// every link (`MouseController.setDPITable`), so it is kept in the active slot.
    var supportsDpiModes = false
    /// Lighting set zone by zone (`ZonedLighting`), in the picker's order; empty when the
    /// mouse is lit as one.
    var lightingZones: [LightingZone] = []
    /// The mouse's button function table (`OnboardButtons.layout`), when it is known; nil
    /// leaves remaps to the event tap alone.
    var buttonTable: OnboardButtons.Table?
    /// The stage table's active stage and stage numbers count from 1, as OpenRazer writes
    /// them, instead of from 0 (`RazerCommands.setDPIStages`). USB only: the Bluetooth table
    /// always counts from 1 and `BLEProtocol` converts it.
    var dpiStagesCountFromOne = false
}

enum RazerDevices {
    static let vendorID = 0x1532

    /// The Basilisk V4 Pro's lighting zones, the same on every link.
    static let basiliskV4ProZones: [LightingZone] = [.logo, .scrollWheel, .underglow]

    static let known: [RazerDeviceInfo] = [
        // 0x1f throughout: hardware-verified on the HyperSpeed (both PIDs), and what
        // OpenRazer uses for the whole Cobra Pro family.
        .init(pid: 0x00DB, name: "Razer Cobra HyperSpeed", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobraPro, dischargeCurveModelKey: "cobra-hyperspeed"),
        .init(pid: 0x00DA, name: "Razer Cobra HyperSpeed (Wired)", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobraPro, dischargeCurveModelKey: "cobra-hyperspeed"),
        // Over Bluetooth (vendor 0x068E). Hardware-verified with this app: battery, serial,
        // DPI stages and brightness on LOGO_LED, the same LED as over USB. Transaction ids
        // don't apply: BLE frames carry their own request id.
        .init(pid: 0x00DC, name: "Razer Cobra HyperSpeed (Bluetooth)", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .bluetooth, silhouette: .cobraPro, dischargeCurveModelKey: "cobra-hyperspeed"),
        // Basilisk V3 X HyperSpeed over Bluetooth. The shared BLE layer covers battery, DPI,
        // stages and static lighting; the DPI Cycle assignment is handled by BluetoothDevice.
        // Its only lit zone is the scroll wheel, so brightness must target SCROLL_LED.
        .init(pid: 0x00BA, name: "Razer Basilisk V3 X HyperSpeed (Bluetooth)", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 18000, transactionId: 0x1f, matrixTransactionId: 0x1f, brightnessLed: Razer.scrollLed, connection: .bluetooth, silhouette: .cobra, dischargeCurveModelKey: nil, supportsDpiButtonBinding: true, supportsSleepTimeout: true, supportsStageEditing: true, verifiesBrightnessWrite: true),
        // Plain Cobra per razermouse_driver.c: 0xFF for standard/misc (serial :1509,
        // polling :2011/:2193, DPI :2600/:2781) but 0x1f for every extended-matrix
        // command (brightness :4202/:4312, spectrum :4622, static :5085, none :5301).
        // Not yet re-verified on hardware with this app.
        .init(pid: 0x00A3, name: "Razer Cobra", fullySupported: true, hasBattery: false, hasLighting: true, maxDPI: 8500, transactionId: 0xff, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        .init(pid: 0x00AF, name: "Razer Cobra Pro (Wired)", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobraPro, dischargeCurveModelKey: nil),
        .init(pid: 0x00B0, name: "Razer Cobra Pro (Wireless)", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 30000, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .cobraPro, dischargeCurveModelKey: nil),
        // OpenRazer uses 0xFF for the Atheris, but 0x1f is what this app was hardware-tested
        // with (README) — verified behavior wins over the reference here.
        .init(pid: 0x0062, name: "Razer Atheris", fullySupported: true, hasBattery: true, hasLighting: false, maxDPI: 7200, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wirelessDongle, silhouette: .atheris, dischargeCurveModelKey: nil),
        // Basilisk V3 X HyperSpeed: AA-cell wireless (2.4 GHz dongle or Bluetooth — no
        // charging, so `is_charging` is always false). Scroll-wheel-only lighting. 0x1f
        // everywhere per razermouse_driver.c.
        //
        // Hardware-verified with this app: battery, DPI read/write, the stage table, polling
        // rate, lighting effects, and brightness on SCROLL_LED. The 18000 ceiling is the
        // vendor spec — the reporter exercised DPI at 6400, so the top of the range is the
        // one field here not demonstrated on a device.
        .init(pid: 0x00B9, name: "Razer Basilisk V3 X HyperSpeed", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 18000, transactionId: 0x1f, matrixTransactionId: 0x1f, brightnessLed: Razer.scrollLed, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Basilisk V4 Pro: rechargeable, cable or HyperSpeed dongle. Probed on hardware with
        // this app on both PIDs (firmware v1.1): 0x1f answers every command and is the only
        // usable id over the dongle (0x3f/0xff/0x80 time out there). Battery and charging, DPI
        // and the 5-stage table, brightness on LOGO and SCROLL, polling (`usesPollingRate2`),
        // the wheel controls, the low-battery threshold and every remap saved in the mouse
        // (`OnboardButtons`) were confirmed on the mouse (2026-10-19), so fullySupported.
        // 50000 DPI, the vendor spec: the mouse kept 50000 for the DPI and a stage over the
        // dongle, and for a stage over Bluetooth.
        .init(pid: 0x00E2, name: "Razer Basilisk V4 Pro (Wired)", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 50000, transactionId: 0x1f, matrixTransactionId: 0x1f, brightnessLed: Razer.logoLed, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil, supportsSleepTimeout: true, usesPollingRate2: true, hasWheelControls: true, hasSmartReelSensitivity: true, hasScrollAcceleration: true, supportsLowBatteryThreshold: true, hasOnboardSlots: true, supportsDpiModes: true, lightingZones: basiliskV4ProZones, buttonTable: .basiliskV4Pro, dpiStagesCountFromOne: true),
        .init(pid: 0x00E3, name: "Razer Basilisk V4 Pro (Wireless)", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 50000, transactionId: 0x1f, matrixTransactionId: 0x1f, brightnessLed: Razer.logoLed, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil, supportsSleepTimeout: true, usesPollingRate2: true, hasWheelControls: true, hasSmartReelSensitivity: true, hasScrollAcceleration: true, supportsLowBatteryThreshold: true, hasOnboardSlots: true, supportsDpiModes: true, lightingZones: basiliskV4ProZones, buttonTable: .basiliskV4Pro, dpiStagesCountFromOne: true),
        // Over Bluetooth it names itself "BSK V4 PRO" (vendor 0x068E). Read on the mouse through
        // the shared BLE layer: battery, serial, DPI stages, LOGO brightness and the sleep
        // timer all answered, and DPI and brightness changes from the app worked. Remaps are
        // saved in its button table (`OnboardButtons`), the same table as over the dongle and
        // cable; the side trigger has no entry there, and the wheel settings and low-battery
        // threshold are USB-only so far.
        .init(pid: 0x00E4, name: "Razer Basilisk V4 Pro (Bluetooth)", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 50000, transactionId: 0x1f, matrixTransactionId: 0x1f, brightnessLed: Razer.logoLed, connection: .bluetooth, silhouette: .cobra, dischargeCurveModelKey: nil, supportsSleepTimeout: true, supportsStageEditing: true, supportsLowBatteryThreshold: true, hasOnboardSlots: true, supportsDpiModes: true, lightingZones: basiliskV4ProZones, buttonTable: .basiliskV4Pro),
        // Basilisk X HyperSpeed: the older AA-cell sibling — no lighting at all, and
        // razermouse_driver.c gives it 0xFF for every command it supports. Not verified
        // on hardware by us.
        .init(pid: 0x0083, name: "Razer Basilisk X HyperSpeed", fullySupported: false, hasBattery: true, hasLighting: false, maxDPI: 16000, transactionId: 0xff, matrixTransactionId: 0xff, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Basilisk V3 (user-reported working): wired-only, 11-zone lighting. Per
        // razermouse_driver.c it takes 0x1f everywhere except the DPI-stages pair, which it
        // shares with the plain Cobra's 0xFF group. Not yet re-verified on hardware by us.
        .init(pid: 0x0099, name: "Razer Basilisk V3", fullySupported: false, hasBattery: false, hasLighting: true, maxDPI: 26000, transactionId: 0x1f, matrixTransactionId: 0x1f, transactionOverrides: [0x0406: 0xff, 0x0486: 0xff], connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Orochi2013
        .init(pid: 0x0039, name: "Razer Orochi 2013", fullySupported: false, hasBattery: false, hasLighting: false, maxDPI: 6400, transactionId: 0x1f, matrixTransactionId: 0x1f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Viper Ultimate (Wireless)
        .init(pid: 0x007b, name: "Razer Viper Ultimate (Wireless)", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 20000, transactionId: 0xff, matrixTransactionId: 0x3f, connection: .wirelessDongle, silhouette: .cobra, dischargeCurveModelKey: nil),
        // Viper Ultimate (Wired)
        .init(pid: 0x007a, name: "Razer Viper Ultimate (Wired)", fullySupported: false, hasBattery: true, hasLighting: true, maxDPI: 20000, transactionId: 0xff, matrixTransactionId: 0x3f, connection: .wired, silhouette: .cobra, dischargeCurveModelKey: nil),
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
    /// Defaults assume a full-featured mouse for unknown models (so we still attempt controls).
    static func hasBattery(pid: Int) -> Bool { info(pid: pid)?.hasBattery ?? true }
    static func hasLighting(pid: Int) -> Bool { info(pid: pid)?.hasLighting ?? true }
    static func maxDPI(pid: Int) -> Int { info(pid: pid)?.maxDPI ?? 26000 }
    static func supportsDpiButtonBinding(pid: Int) -> Bool { info(pid: pid)?.supportsDpiButtonBinding ?? false }
    static func supportsSleepTimeout(pid: Int) -> Bool { info(pid: pid)?.supportsSleepTimeout ?? false }
    static func supportsStageEditing(pid: Int) -> Bool { info(pid: pid)?.supportsStageEditing ?? false }
    /// Mice whose stage table holds their DPI in the active onboard slot on every link, so
    /// the popover offers Single and Stages modes there instead of the slider and presets.
    static func supportsDpiModes(pid: Int) -> Bool { info(pid: pid)?.supportsDpiModes ?? false }
    static func usesPollingRate2(pid: Int) -> Bool { info(pid: pid)?.usesPollingRate2 ?? false }
    static func hasWheelControls(pid: Int) -> Bool { info(pid: pid)?.hasWheelControls ?? false }
    static func hasSmartReelSensitivity(pid: Int) -> Bool { info(pid: pid)?.hasSmartReelSensitivity ?? false }
    static func hasScrollAcceleration(pid: Int) -> Bool { info(pid: pid)?.hasScrollAcceleration ?? false }
    static func supportsLowBatteryThreshold(pid: Int) -> Bool { info(pid: pid)?.supportsLowBatteryThreshold ?? false }
    static func hasOnboardSlots(pid: Int) -> Bool { info(pid: pid)?.hasOnboardSlots ?? false }
    static func lightingZones(pid: Int?) -> [LightingZone] { pid.flatMap { info(pid: $0)?.lightingZones } ?? [] }
    static func buttonTable(pid: Int) -> OnboardButtons.Table? { info(pid: pid)?.buttonTable }
    static func dpiStagesCountFromOne(pid: Int) -> Bool { info(pid: pid)?.dpiStagesCountFromOne ?? false }
    static func verifiesBrightnessWrite(pid: Int) -> Bool { info(pid: pid)?.verifiesBrightnessWrite ?? false }
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
}

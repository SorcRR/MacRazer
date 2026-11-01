// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class RazerDevicesTests: XCTestCase {
    /// Transaction ids go on the wire for every command (stamped in HIDDevice.send) — pin
    /// them so a registry edit can't silently change the protocol for a verified model.
    /// The misc class (0x07 here) and the extended-matrix class (0x0F) are checked
    /// separately because OpenRazer splits the plain Cobra between them.
    func testTransactionIds() {
        func txn(_ pid: Int, _ cls: UInt8, _ id: UInt8 = 0x80) -> UInt8 {
            RazerDevices.transactionId(pid: pid, commandClass: cls, commandId: id)
        }
        let misc: UInt8 = 0x07, matrix: UInt8 = 0x0F
        for cls in [misc, matrix] {
            XCTAssertEqual(txn(0x00DB, cls), 0x1f) // HyperSpeed (hardware-verified)
            XCTAssertEqual(txn(0x00DA, cls), 0x1f)
            XCTAssertEqual(txn(0x00AF, cls), 0x1f) // Cobra Pro (OpenRazer)
            XCTAssertEqual(txn(0x00B0, cls), 0x1f)
            XCTAssertEqual(txn(0x0062, cls), 0x1f) // Atheris (hardware-verified)
            XCTAssertEqual(txn(0x0090, cls), 0x1f) // Naga Pro dongle (hardware-verified, #69)
            XCTAssertEqual(txn(0x008F, cls), 0x1f)
            XCTAssertEqual(txn(0x00E8, cls), 0x1f) // Naga V3 Pro dongle (hardware-verified, #33)
            XCTAssertEqual(txn(0x00EA, cls), 0x1f) // Basilisk V4 HyperSpeed dongle (hardware-verified)
            XCTAssertEqual(txn(0x00E7, cls), 0x1f) // Naga V3 Pro cable (hardware-verified, #33)
            XCTAssertEqual(txn(0x0067, cls), 0x1f) // Naga Trinity (hardware-verified)
            XCTAssertEqual(txn(0x0053, cls), 0x1f) // Naga Chroma (hardware-verified)
            XCTAssertEqual(txn(0x00A4, cls), 0x1f) // Mouse Dock Pro (hardware-verified)
            XCTAssertEqual(txn(0x00E3, cls), 0x1f) // Basilisk V4 Pro dongle (hardware-verified)
            XCTAssertEqual(txn(0x00C5, cls), 0x1f) // DeathAdder V3 HyperSpeed dongle (hardware-verified)
            XCTAssertEqual(txn(0x007D, cls), 0x1f) // DeathAdder V2 Pro dongle (hardware-verified)
            XCTAssertEqual(txn(0x00B8, cls), 0x1f) // Viper V3 HyperSpeed dongle (hardware-verified)
            XCTAssertEqual(txn(0x00E5, cls), 0x1f) // Viper V4 Pro cable (hardware-verified)
            XCTAssertEqual(txn(0x9999, cls), 0x1f) // unknown → Cobra default
        }
        // Plain Cobra: 0xFF for standard/misc, but 0x1f for extended-matrix (lighting) —
        // per razermouse_driver.c's per-command switches.
        XCTAssertEqual(txn(0x00A3, misc), 0xff)
        XCTAssertEqual(txn(0x00A3, 0x00), 0xff)
        XCTAssertEqual(txn(0x00A3, matrix), 0x1f)
        // Basilisk V3: 0x1f everywhere EXCEPT the DPI-stages pair (per-command override,
        // shared with the plain Cobra's 0xFF group in razermouse_driver.c).
        XCTAssertEqual(txn(0x0099, 0x04, 0x05), 0x1f) // set DPI
        XCTAssertEqual(txn(0x0099, 0x04, 0x85), 0x1f) // get DPI
        XCTAssertEqual(txn(0x0099, 0x04, 0x06), 0xff) // set DPI stages
        XCTAssertEqual(txn(0x0099, 0x04, 0x86), 0xff) // get DPI stages
        XCTAssertEqual(txn(0x0099, matrix, 0x02), 0x1f) // lighting
        // Basilisk V3 X HyperSpeed: 0x1f for every class (hardware-verified — battery,
        // DPI, polling and scroll brightness all answer). Its older sibling, the plain
        // Basilisk X HyperSpeed, takes 0xFF everywhere per razermouse_driver.c.
        for cls in [misc, matrix] {
            XCTAssertEqual(txn(0x00B9, cls), 0x1f)
            XCTAssertEqual(txn(0x0083, cls), 0xff)
        }
    }

    /// The brightness LED id is not the same across models and a wrong one is not a silent
    /// no-op — the device answers FAILURE (0x03) and the brightness slider stops working.
    func testBrightnessLedPerModel() {
        // Cobra family: only LOGO_LED answers (ZERO/BACKLIGHT refuse).
        XCTAssertEqual(RazerDevices.brightnessLed(pid: 0x00DB), Razer.logoLed)
        XCTAssertEqual(RazerDevices.brightnessLed(pid: 0x00A3), Razer.logoLed)
        // Basilisk V3 X HyperSpeed lights only its scroll wheel — hardware-verified that
        // SCROLL_LED answers and LOGO, ZERO and BACKLIGHT all return 0x03.
        XCTAssertEqual(RazerDevices.brightnessLed(pid: 0x00B9), Razer.scrollLed)
        // From the in-app reports: the Trinity and the Basilisk V4 Pro answer on LOGO and
        // SCROLL only. The Mouse Dock Pro stays on LOGO, whichever mouse is paired to it.
        XCTAssertEqual(RazerDevices.brightnessLeds(pid: 0x0067), [Razer.logoLed, Razer.scrollLed])
        XCTAssertEqual(RazerDevices.brightnessLeds(pid: 0x00E3), [Razer.logoLed, Razer.scrollLed])
        XCTAssertEqual(RazerDevices.brightnessLeds(pid: 0x00A4), [Razer.logoLed])
        XCTAssertEqual(RazerDevices.brightnessLeds(pid: 0x00E7), [Razer.logoLed, Razer.scrollLed, Razer.backlightLed])
        // Unknown models keep the Cobra-family default.
        XCTAssertEqual(RazerDevices.brightnessLed(pid: 0x9999), Razer.logoLed)
        XCTAssertEqual(RazerDevices.brightnessLed(pid: nil), Razer.logoLed)
    }

    /// The two Basilisk HyperSpeed models differ in exactly the ways that matter for the
    /// UI: the V3 X has scroll lighting and a higher ceiling, the plain X has no lighting.
    func testBasiliskHyperSpeedCapabilities() {
        XCTAssertTrue(RazerDevices.hasBattery(pid: 0x00B9))
        XCTAssertTrue(RazerDevices.hasLighting(pid: 0x00B9))
        XCTAssertEqual(RazerDevices.maxDPI(pid: 0x00B9), 18000)
        XCTAssertEqual(RazerDevices.connection(pid: 0x00B9), .wirelessDongle)

        XCTAssertTrue(RazerDevices.hasBattery(pid: 0x0083))
        XCTAssertFalse(RazerDevices.hasLighting(pid: 0x0083), "the plain X HyperSpeed has no RGB at all")
        XCTAssertEqual(RazerDevices.maxDPI(pid: 0x0083), 16000)

        // Both are AA-cell mice, so neither shares the Cobra's learned discharge curve.
        XCTAssertNil(RazerDevices.dischargeCurveModelKey(pid: 0x00B9))
        XCTAssertNil(RazerDevices.dischargeCurveModelKey(pid: 0x0083))
    }

    /// `testBrightnessLedPerModel` checks the lookup in isolation; this checks the
    /// composition — registry lookup fed into the command builder — actually lands the
    /// model's id in `arguments[1]`, the byte the mouse reads. Verified non-vacuous by
    /// removing `brightnessLed` from the Basilisk entry: it fails with 4 != 1.
    ///
    /// What neither test can reach is `MouseController` passing the right pid in the first
    /// place, which is where the original bug lived — that needs a device. Making `led:`
    /// a required parameter is what actually guards that: a call site can no longer fall
    /// back to LOGO_LED by saying nothing.
    func testBrightnessCommandsCarryTheModelsLed() {
        func setLed(_ pid: Int?) -> UInt8 {
            RazerCommands.setBrightness(128, led: RazerDevices.brightnessLed(pid: pid)).arguments[1]
        }
        func getLed(_ pid: Int?) -> UInt8 {
            RazerCommands.getBrightness(led: RazerDevices.brightnessLed(pid: pid)).arguments[1]
        }
        // Cobra HyperSpeed — the family the old hardcoded value happened to suit.
        XCTAssertEqual(setLed(0x00DB), Razer.logoLed)
        XCTAssertEqual(getLed(0x00DB), Razer.logoLed)
        // Basilisk V3 X HyperSpeed: scroll wheel only. Sending LOGO here is the silent
        // no-op — the mouse answers FAILURE and the slider does nothing.
        XCTAssertEqual(setLed(0x00B9), Razer.scrollLed)
        XCTAssertEqual(getLed(0x00B9), Razer.scrollLed)
        // Unknown model, and no device at all, both fall back to the Cobra family's id.
        XCTAssertEqual(setLed(0x9999), Razer.logoLed)
        XCTAssertEqual(setLed(nil), Razer.logoLed)
    }

    /// The Nagas light three zones and each takes its own brightness. Every other model
    /// writes just its one `brightnessLed`.
    func testBrightnessLedsCoverEveryZone() {
        let naga = [Razer.logoLed, Razer.scrollLed, Razer.backlightLed]
        for pid in [0x0090, 0x008F, 0x00E8] {
            XCTAssertEqual(RazerDevices.brightnessLeds(pid: pid), naga)
        }
        XCTAssertEqual(RazerDevices.brightnessLeds(pid: 0x00DB), [Razer.logoLed])
        XCTAssertEqual(RazerDevices.brightnessLeds(pid: 0x00B9), [Razer.scrollLed])
        XCTAssertEqual(RazerDevices.brightnessLeds(pid: 0x9999), [Razer.logoLed])
        XCTAssertEqual(RazerDevices.brightnessLeds(pid: nil), [Razer.logoLed])
    }

    func testWriteBrightnessSetsEveryZoneAndStopsOnARefusal() throws {
        let naga = RecordingTransport(productID: 0x00E8)
        try MouseController.writeBrightness(128, to: naga)
        XCTAssertEqual(naga.sent.map { $0.arguments[1] }, [Razer.logoLed, Razer.scrollLed, Razer.backlightLed])
        XCTAssertTrue(naga.sent.allSatisfy { $0.commandId == 0x04 && $0.arguments[2] == 128 })

        let refusing = RecordingTransport(productID: 0x00E8, refuses: Razer.scrollLed)
        XCTAssertThrowsError(try MouseController.writeBrightness(128, to: refusing))
        XCTAssertEqual(refusing.sent.map { $0.arguments[1] }, [Razer.logoLed, Razer.scrollLed])
    }

    /// Which link is still worth a report: the Naga Pro is verified over its dongle only.
    func testFullySupportedOnAnotherLink() {
        XCTAssertEqual(RazerDevices.modelName("Razer Naga Pro (Wired)"), "Razer Naga Pro")
        XCTAssertEqual(RazerDevices.modelName("Razer Cobra HyperSpeed"), "Razer Cobra HyperSpeed")
        XCTAssertTrue(RazerDevices.fullySupported(modelOf: 0x008F, on: .wirelessDongle))
        XCTAssertFalse(RazerDevices.fullySupported(modelOf: 0x0090, on: .wired))
        XCTAssertTrue(RazerDevices.fullySupported(modelOf: 0x00DB, on: .wired), "Cobra HyperSpeed (Wired)")
        XCTAssertTrue(RazerDevices.fullySupported(modelOf: 0x00E8, on: .wired), "Naga V3 Pro (Wired)")
        XCTAssertFalse(RazerDevices.fullySupported(modelOf: 0x00E3, on: .wired), "no cable row at all")
        XCTAssertFalse(RazerDevices.fullySupported(modelOf: 0x9999, on: .wired))
    }

    /// What each row still needs, and what that leaves verified.
    func testVerifiedAndUnverifiedFeatures() {
        XCTAssertEqual(RazerDevices.unverified(pid: 0x00DB), [])
        XCTAssertTrue(RazerDevices.fullySupported(pid: 0x00DB))
        XCTAssertEqual(RazerDevices.unverified(pid: 0x00C5), [.battery])
        XCTAssertFalse(RazerDevices.fullySupported(pid: 0x00C5))
        XCTAssertNil(RazerDevices.unverified(pid: 0x9999))
        XCTAssertEqual(RazerDevices.verified(pid: 0x00C5), [.dpi, .polling], "no lighting on the mouse at all")
        XCTAssertEqual(RazerDevices.verified(pid: 0x0067), [.dpi, .polling, .lighting], "wired only: no battery")
        XCTAssertEqual(RazerDevices.verified(pid: 0x0053), [.dpi, .polling], "lighting is hidden and unverified")
        XCTAssertEqual(RazerDevices.verified(pid: 0x9999), [])
    }

    /// Whether a report would still help, on this link or another.
    func testNeedsReport() {
        XCTAssertFalse(RazerDevices.needsReport(pid: 0x00DB), "verified on every link")
        XCTAssertTrue(RazerDevices.needsReport(pid: 0x0090), "verified, but the cable row isn't")
        XCTAssertTrue(RazerDevices.needsReport(pid: 0x00E3), "partly verified")
        XCTAssertTrue(RazerDevices.needsReport(pid: 0x9999), "unknown")
        XCTAssertEqual(RazerDevices.support(pid: 0x0090), .full)
        XCTAssertEqual(RazerDevices.support(pid: 0x008F), .unknown, "on record, nothing shown working")
    }

    /// Which other links of a mouse the intro asks for.
    func testLinksToTest() {
        typealias Link = RazerDevices.LinkToTest
        // A row for the other link that isn't fully supported: named, with what it needs.
        XCTAssertEqual(RazerDevices.linksToTest(besides: 0x0090),
                       [Link(connection: .wired, missing: [.battery, .dpi, .polling, .lighting])])
        // Fully supported on every link it has a row for.
        XCTAssertEqual(RazerDevices.linksToTest(besides: 0x00E8), [])
        XCTAssertEqual(RazerDevices.linksToTest(besides: 0x00DB), [])
        // No row for the cable, and a battery: worth asking, worded with an "if".
        XCTAssertEqual(RazerDevices.linksToTest(besides: 0x00E3), [Link(connection: .wired, missing: nil)])
        // AA-cell mice have no cable mode, so there's nothing to suggest.
        XCTAssertEqual(RazerDevices.linksToTest(besides: 0x0062), [], "Atheris")
        XCTAssertEqual(RazerDevices.linksToTest(besides: 0x00B9), [], "Basilisk V3 X HyperSpeed")
        // Wired only, and Bluetooth never suggested without a row.
        XCTAssertEqual(RazerDevices.linksToTest(besides: 0x0067), [])
        XCTAssertEqual(RazerDevices.linksToTest(besides: 0x9999), [])
    }

    /// A cable report from a Naga Pro answers the dongle row's ask for a cable test, whether
    /// the cable's product id is on record or not. A report from the dongle answers nothing.
    func testReportAnswersTheRowThatAskedForIt() {
        XCTAssertEqual(RazerDevices.rowsAnswered(byReportFrom: 0x008F, name: "Razer Naga Pro", on: .wired), [0x0090])
        XCTAssertEqual(RazerDevices.rowsAnswered(byReportFrom: 0xFFF0, name: "Razer Naga Pro", on: .wired), [0x0090])
        XCTAssertEqual(RazerDevices.rowsAnswered(byReportFrom: 0x0090, name: "Razer Naga Pro", on: .wirelessDongle), [])
        XCTAssertEqual(RazerDevices.rowsAnswered(byReportFrom: 0xFFF0, name: "Razer Something Else", on: .wired), [])
    }

    /// The Viper V3 HyperSpeed has no lighting and a 26K sensor. Its firmware echoes DPI writes
    /// far above that, so only the registry keeps the slider honest.
    func testViperV3HyperSpeedCapabilities() {
        XCTAssertTrue(RazerDevices.fullySupported(pid: 0x00B8))
        XCTAssertTrue(RazerDevices.hasBattery(pid: 0x00B8))
        XCTAssertFalse(RazerDevices.hasLighting(pid: 0x00B8))
        XCTAssertEqual(RazerDevices.maxDPI(pid: 0x00B8), 26000)
        XCTAssertEqual(RazerDevices.connection(pid: 0x00B8), .wirelessDongle)
        XCTAssertEqual(RazerDevices.linksToTest(besides: 0x00B8), [], "an AA-cell mouse has no cable mode")
    }

    /// The Viper V4 Pro on its cable: no lighting, polling still to verify, and the classic
    /// polling command refused, so the picker stays hidden.
    func testViperV4ProWiredCapabilities() {
        XCTAssertEqual(RazerDevices.unverified(pid: 0x00E5), [.polling])
        XCTAssertTrue(RazerDevices.hasBattery(pid: 0x00E5))
        XCTAssertFalse(RazerDevices.hasLighting(pid: 0x00E5))
        XCTAssertEqual(RazerDevices.maxDPI(pid: 0x00E5), 45000)
        XCTAssertEqual(RazerDevices.connection(pid: 0x00E5), .wired)
    }

    /// The models that answer the classic polling command with "not supported".
    func testClassicPollingRefusals() {
        for pid in [0x00A4, 0x00EA, 0x00E3, 0x00E5] {
            XCTAssertFalse(RazerDevices.acceptsClassicPolling(pid: pid), String(pid, radix: 16))
        }
        XCTAssertTrue(RazerDevices.acceptsClassicPolling(pid: 0x00DB))
        XCTAssertTrue(RazerDevices.acceptsClassicPolling(pid: 0x9999), "unknown models still try it")
    }

    /// The Basilisk V3 verified on its cable, with both lit zones on the brightness slider.
    func testBasiliskV3Verified() {
        XCTAssertTrue(RazerDevices.fullySupported(pid: 0x0099))
        XCTAssertFalse(RazerDevices.hasBattery(pid: 0x0099))
        XCTAssertEqual(RazerDevices.info(pid: 0x0099)?.extraBrightnessLeds, [Razer.scrollLed])
        XCTAssertEqual(RazerDevices.linksToTest(besides: 0x0099), [], "wired only, nothing else to ask for")
    }

    /// The DeathAdder Essential: wired, no battery, and a green-only light whose brightness is
    /// all there is to verify. Nothing left to ask its owners for.
    func testDeathAdderEssential() {
        XCTAssertTrue(RazerDevices.fullySupported(pid: 0x0098))
        XCTAssertFalse(RazerDevices.needsReport(pid: 0x0098))
        XCTAssertFalse(RazerDevices.hasBattery(pid: 0x0098))
        XCTAssertEqual(RazerDevices.maxDPI(pid: 0x0098), 6400)
        XCTAssertEqual(RazerDevices.connection(pid: 0x0098), .wired)
        XCTAssertTrue(RazerDevices.fixedColor(pid: 0x0098), "green only: brightness, no colours")
        // The older Essentials, from OpenRazer: 0xFF and nothing verified.
        for pid in [0x006E, 0x0071] {
            XCTAssertEqual(RazerDevices.unverified(pid: pid), [.dpi, .polling])
            XCTAssertEqual(RazerDevices.transactionId(pid: pid, commandClass: 0x04, commandId: 0x05), 0xff)
            XCTAssertFalse(RazerDevices.hasLighting(pid: pid))
        }
    }

    func testConnectionKind() {
        XCTAssertEqual(RazerDevices.connection(pid: 0x00DB), .wirelessDongle)
        XCTAssertEqual(RazerDevices.connection(pid: 0x00DA), .wired)
        XCTAssertEqual(RazerDevices.connection(pid: 0x0099), .wired) // Basilisk V3: wired-only
        XCTAssertEqual(RazerDevices.connection(pid: 0x00DC), .bluetooth)
        XCTAssertNil(RazerDevices.connection(pid: 0x9999), "unknown models show the neutral USB chip")
        XCTAssertNil(RazerDevices.connection(pid: nil))
    }

    /// Bluetooth PIDs come from Razer's Bluetooth vendor id (0x068E), USB ones from 0x1532,
    /// but the registry is keyed by PID alone. A clash would hand one model's capabilities
    /// to the other, so keep every row's PID unique.
    func testPIDsAreUnique() {
        let pids = RazerDevices.known.map(\.pid)
        XCTAssertEqual(pids.count, Set(pids).count)
    }

    /// The Bluetooth Cobra HyperSpeed is the same mouse as the dongle one: same LED for
    /// brightness (verified over BLE: LOGO answers, SCROLL refuses) and same discharge curve.
    func testBluetoothCobraHyperSpeed() {
        XCTAssertEqual(RazerDevices.bluetoothPIDs, [0x00BA, 0x00DC])
        XCTAssertEqual(RazerDevices.bluetoothModelNames, ["Razer Cobra HyperSpeed", "Razer Basilisk V3 X HyperSpeed"],
                       "user-facing text names the model, not the link")
        XCTAssertEqual(RazerDevices.brightnessLed(pid: 0x00DC), Razer.logoLed)
        XCTAssertEqual(RazerDevices.dischargeCurveModelKey(pid: 0x00DC),
                       RazerDevices.dischargeCurveModelKey(pid: 0x00DB))
        XCTAssertEqual(RazerDevices.maxDPI(pid: 0x00DC), RazerDevices.maxDPI(pid: 0x00DB))
    }

    func testBluetoothBasiliskHyperSpeed() {
        XCTAssertEqual(RazerDevices.connection(pid: 0x00BA), .bluetooth)
        XCTAssertTrue(RazerDevices.hasBattery(pid: 0x00BA))
        XCTAssertTrue(RazerDevices.hasLighting(pid: 0x00BA))
        XCTAssertEqual(RazerDevices.brightnessLed(pid: 0x00BA), Razer.scrollLed)
        XCTAssertEqual(RazerDevices.maxDPI(pid: 0x00BA), 18000)
        XCTAssertTrue(RazerDevices.supportsDpiButtonBinding(pid: 0x00BA))
        XCTAssertTrue(RazerDevices.supportsSleepTimeout(pid: 0x00BA))
        XCTAssertTrue(RazerDevices.supportsStageEditing(pid: 0x00BA))
        XCTAssertFalse(RazerDevices.supportsDpiButtonBinding(pid: 0x00DC))
        XCTAssertFalse(RazerDevices.supportsSleepTimeout(pid: 0x00DC))
        XCTAssertFalse(RazerDevices.supportsStageEditing(pid: 0x00DC))
        XCTAssertTrue(RazerDevices.verifiesBrightnessWrite(pid: 0x00BA))
        XCTAssertFalse(RazerDevices.verifiesBrightnessWrite(pid: 0x00DC),
                       "the Cobra's brightness isn't read back after writing")
    }

    func testCapabilityDefaultsForUnknownModels() {
        // Unknown mice are assumed full-featured so the app still attempts controls.
        XCTAssertTrue(RazerDevices.hasBattery(pid: 0x9999))
        XCTAssertTrue(RazerDevices.hasLighting(pid: 0x9999))
        XCTAssertFalse(RazerDevices.fullySupported(pid: 0x9999))
        XCTAssertNil(RazerDevices.dischargeCurveModelKey(pid: 0x9999))
    }

    func testSilhouetteMapping() {
        XCTAssertEqual(RazerDevices.silhouette(pid: 0x00DB), .cobraPro)
        XCTAssertEqual(RazerDevices.silhouette(pid: 0x0062), .atheris)
        XCTAssertEqual(RazerDevices.silhouette(pid: 0x9999), .cobra) // unknown → generic body
        XCTAssertEqual(RazerDevices.silhouette(pid: nil), .cobra)
    }

    func testProfileSummaryOmitsEmptyEffect() {
        // Profiles saved on lighting-less mice store an empty effect — the summary must not
        // show a lighting mode the mouse can't have.
        var p = MouseProfile(name: "A", dpi: 1600, pollRate: 1000, brightness: 100,
                             effect: "", color: RGB(r: 0, g: 0, b: 0), buttonMappings: [:])
        XCTAssertEqual(p.summary, "1600 DPI · 1000 Hz")
        XCTAssertEqual(p.lightingEffect, .off, "empty effect degrades to off on apply")
        p.effect = LightingEffect.wave.rawValue
        XCTAssertEqual(p.summary, "1600 DPI · 1000 Hz · Wave")
    }

    func testLightingEffectRawValuesAreFrozen() {
        // Raw values are persisted in saved profiles — renaming a case orphans user data.
        XCTAssertEqual(LightingEffect.staticColor.rawValue, "Static")
        XCTAssertEqual(LightingEffect.breathing.rawValue, "Breathing")
        XCTAssertEqual(LightingEffect.spectrum.rawValue, "Spectrum")
        XCTAssertEqual(LightingEffect.wave.rawValue, "Wave")
        XCTAssertEqual(LightingEffect.off.rawValue, "Off")
    }
}

/// Records every report and answers it, or throws for one LED group.
private final class RecordingTransport: RazerTransport {
    let productID: Int
    let productName = "Test mouse"
    let locationID = 1
    let isBluetooth = false
    let refuses: UInt8?
    private(set) var sent: [RazerReport] = []

    init(productID: Int, refuses: UInt8? = nil) {
        self.productID = productID
        self.refuses = refuses
    }

    func sendWithRetry(_ report: RazerReport) throws -> RazerReport {
        sent.append(report)
        if report.arguments[1] == refuses { throw HIDDevice.HIDError.commandFailed }
        return report
    }

    func close() {}
}

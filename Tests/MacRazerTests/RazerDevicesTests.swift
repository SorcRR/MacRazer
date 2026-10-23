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

    /// Basilisk V4 Pro, from the hardware probe on both links: 0x1f is the only id the dongle
    /// answers, both PIDs report battery, and brightness answers on LOGO (and SCROLL).
    func testBasiliskV4Pro() {
        for pid in [0x00E2, 0x00E3] {
            for cls: UInt8 in [0x00, 0x04, 0x07, 0x0F] {
                XCTAssertEqual(RazerDevices.transactionId(pid: pid, commandClass: cls, commandId: 0x80), 0x1f)
            }
            XCTAssertTrue(RazerDevices.hasBattery(pid: pid))
            XCTAssertTrue(RazerDevices.hasLighting(pid: pid))
            XCTAssertEqual(RazerDevices.brightnessLed(pid: pid), Razer.logoLed)
            XCTAssertEqual(RazerDevices.maxDPI(pid: pid), 50000, "50000 was read back on the mouse")
            XCTAssertTrue(RazerDevices.fullySupported(pid: pid), "confirmed on the mouse, 2026-10-19")
        }
        XCTAssertTrue(RazerDevices.fullySupported(pid: 0x00E4))
        XCTAssertEqual(RazerDevices.connection(pid: 0x00E2), .wired)
        XCTAssertEqual(RazerDevices.connection(pid: 0x00E3), .wirelessDongle)
    }

    /// The threshold byte is on the battery's 0-255 scale: the factory 0x55 reads 33%, and
    /// every whole percentage survives a write and read back.
    func testLowBatteryThreshold() {
        var r = RazerReport(commandClass: 0x07, commandId: 0x82, dataSize: 0x01)
        r.arguments[0] = 0x55
        XCTAssertEqual(RazerCommands.parseLowBatteryThreshold(r), 33)
        for percent in 0...100 {
            r.arguments[0] = RazerCommands.setLowBatteryThreshold(percent: percent).arguments[0]
            XCTAssertEqual(RazerCommands.parseLowBatteryThreshold(r), percent)
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
        XCTAssertEqual(RazerDevices.bluetoothPIDs, [0x00BA, 0x00DC, 0x00E4])
        XCTAssertEqual(RazerDevices.bluetoothModelNames,
                       ["Razer Cobra HyperSpeed", "Razer Basilisk V3 X HyperSpeed", "Razer Basilisk V4 Pro"],
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

    func testBluetoothBasiliskV4Pro() {
        XCTAssertEqual(RazerDevices.connection(pid: 0x00E4), .bluetooth)
        XCTAssertEqual(RazerDevices.brightnessLed(pid: 0x00E4), Razer.logoLed)
        XCTAssertEqual(RazerDevices.maxDPI(pid: 0x00E4), RazerDevices.maxDPI(pid: 0x00E3))
        XCTAssertTrue(RazerDevices.supportsSleepTimeout(pid: 0x00E4))
        XCTAssertTrue(RazerDevices.supportsStageEditing(pid: 0x00E4))
        XCTAssertFalse(RazerDevices.supportsDpiButtonBinding(pid: 0x00E4))
        XCTAssertEqual(HIDDevice.classifyBluetoothMouse(vendorID: 0x068E, productID: 0x00E4, name: "BSK V4 PRO"),
                       .init(name: "BSK V4 PRO", controllablePID: 0x00E4))
        XCTAssertEqual(HIDDevice.classifyBluetoothMouse(vendorID: nil, productID: nil, name: "BSK V4 PRO"),
                       .init(name: "BSK V4 PRO", controllablePID: nil), "recognised by name for the hint")
    }

    /// The onboard capabilities are opt-in per row: every mouse that doesn't set them keeps
    /// master's behaviour, including an unknown one.
    func testOnboardCapabilitiesAreOffUnlessARowSetsThem() {
        let v4Pro: Set<Int> = [0x00E2, 0x00E3, 0x00E4]
        for row in RazerDevices.known where !v4Pro.contains(row.pid) {
            XCTAssertFalse(row.usesPollingRate2, row.name)
            XCTAssertFalse(row.hasWheelControls, row.name)
            XCTAssertFalse(row.hasSmartReelSensitivity, row.name)
            XCTAssertFalse(row.hasScrollAcceleration, row.name)
            XCTAssertFalse(row.supportsLowBatteryThreshold, row.name)
            XCTAssertFalse(row.hasOnboardSlots, row.name)
            XCTAssertFalse(row.supportsDpiModes, row.name)
            XCTAssertFalse(row.dpiStagesCountFromOne, row.name)
            XCTAssertEqual(row.lightingZones, [], row.name)
            XCTAssertNil(row.buttonTable, row.name)
            XCTAssertNil(OnboardButtons.layout(pid: row.pid), row.name)
            XCTAssertEqual(RazerCommands.supportedPollingRates(pid: row.pid), RazerCommands.supportedPollingRates, row.name)
            XCTAssertEqual(RazerCommands.setPollingRateReports(1000, pid: row.pid).map(\.commandId), [0x05], row.name)
            if row.connection != .bluetooth { XCTAssertFalse(row.supportsSleepTimeout, row.name) }
        }
        let unknown = 0x9999
        XCTAssertFalse(RazerDevices.usesPollingRate2(pid: unknown))
        XCTAssertFalse(RazerDevices.hasOnboardSlots(pid: unknown))
        XCTAssertFalse(RazerDevices.supportsDpiModes(pid: unknown))
        XCTAssertFalse(RazerDevices.dpiStagesCountFromOne(pid: unknown))
        XCTAssertEqual(RazerDevices.lightingZones(pid: unknown), [])
        XCTAssertEqual(RazerDevices.lightingZones(pid: nil), [])
        XCTAssertNil(OnboardButtons.layout(pid: unknown))
    }

    func testBasiliskV4ProCapabilities() {
        for pid in [0x00E2, 0x00E3] {
            XCTAssertTrue(RazerDevices.usesPollingRate2(pid: pid))
            XCTAssertTrue(RazerDevices.hasWheelControls(pid: pid))
            XCTAssertTrue(RazerDevices.hasSmartReelSensitivity(pid: pid))
            XCTAssertTrue(RazerDevices.hasScrollAcceleration(pid: pid))
            XCTAssertTrue(RazerDevices.supportsSleepTimeout(pid: pid), "0x07/0x83 over USB")
            XCTAssertTrue(RazerDevices.dpiStagesCountFromOne(pid: pid))
            XCTAssertEqual(RazerCommands.supportedPollingRates(pid: pid), [125, 250, 500, 1000, 2000, 4000, 8000])
        }
        XCTAssertEqual(RazerCommands.setPollingRateReports(1000, pid: 0x00E2).map(\.arguments[0]), [0x00])
        XCTAssertEqual(RazerCommands.setPollingRateReports(1000, pid: 0x00E3).map(\.arguments[0]), [0x00, 0x01],
                       "through the dongle: the mouse, then the dongle")
        // Bluetooth: no polling or wheel command there, and BLEProtocol converts the stage table.
        XCTAssertFalse(RazerDevices.usesPollingRate2(pid: 0x00E4))
        XCTAssertFalse(RazerDevices.hasWheelControls(pid: 0x00E4))
        XCTAssertFalse(RazerDevices.hasSmartReelSensitivity(pid: 0x00E4))
        XCTAssertFalse(RazerDevices.hasScrollAcceleration(pid: 0x00E4))
        XCTAssertFalse(RazerDevices.dpiStagesCountFromOne(pid: 0x00E4))
        for pid in [0x00E2, 0x00E3, 0x00E4] {
            XCTAssertTrue(RazerDevices.supportsLowBatteryThreshold(pid: pid))
            XCTAssertTrue(RazerDevices.hasOnboardSlots(pid: pid))
            XCTAssertTrue(RazerDevices.supportsDpiModes(pid: pid))
            XCTAssertEqual(RazerDevices.lightingZones(pid: pid), [.logo, .scrollWheel, .underglow])
            XCTAssertEqual(RazerDevices.buttonTable(pid: pid), .basiliskV4Pro)
        }
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
        XCTAssertEqual(LightingEffect.spectrum.rawValue, "Spectrum")
        XCTAssertEqual(LightingEffect.wave.rawValue, "Wave")
        XCTAssertEqual(LightingEffect.off.rawValue, "Off")
    }
}

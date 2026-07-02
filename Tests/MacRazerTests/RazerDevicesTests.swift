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
        let misc: UInt8 = 0x07, matrix: UInt8 = 0x0F
        for cls in [misc, matrix] {
            XCTAssertEqual(RazerDevices.transactionId(pid: 0x00DB, commandClass: cls), 0x1f) // HyperSpeed (hardware-verified)
            XCTAssertEqual(RazerDevices.transactionId(pid: 0x00DA, commandClass: cls), 0x1f)
            XCTAssertEqual(RazerDevices.transactionId(pid: 0x00AF, commandClass: cls), 0x1f) // Cobra Pro (OpenRazer)
            XCTAssertEqual(RazerDevices.transactionId(pid: 0x00B0, commandClass: cls), 0x1f)
            XCTAssertEqual(RazerDevices.transactionId(pid: 0x0062, commandClass: cls), 0x1f) // Atheris (hardware-verified)
            XCTAssertEqual(RazerDevices.transactionId(pid: 0x9999, commandClass: cls), 0x1f) // unknown → Cobra default
        }
        // Plain Cobra: 0xFF for standard/misc, but 0x1f for extended-matrix (lighting) —
        // per razermouse_driver.c's per-command switches.
        XCTAssertEqual(RazerDevices.transactionId(pid: 0x00A3, commandClass: misc), 0xff)
        XCTAssertEqual(RazerDevices.transactionId(pid: 0x00A3, commandClass: 0x00), 0xff)
        XCTAssertEqual(RazerDevices.transactionId(pid: 0x00A3, commandClass: matrix), 0x1f)
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

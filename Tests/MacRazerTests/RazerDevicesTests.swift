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
    }

    func testConnectionKind() {
        XCTAssertEqual(RazerDevices.connection(pid: 0x00DB), .wirelessDongle)
        XCTAssertEqual(RazerDevices.connection(pid: 0x00DA), .wired)
        XCTAssertEqual(RazerDevices.connection(pid: 0x0099), .wired) // Basilisk V3: wired-only
        XCTAssertNil(RazerDevices.connection(pid: 0x9999), "unknown models show the neutral USB chip")
        XCTAssertNil(RazerDevices.connection(pid: nil))
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

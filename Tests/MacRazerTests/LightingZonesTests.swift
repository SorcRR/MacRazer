// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The Basilisk V4 Pro's per-zone lighting, as the mouse took and reported it (2026-10-19).
final class LightingZonesTests: XCTestCase {
    let red = RGB(r: 0xFF, g: 0, b: 0)

    func testUSBReportCarriesZoneAndBody() {
        let r = ZonedLighting.setEffect(.breathing, color: red, zone: .scrollWheel)
        XCTAssertEqual(r.commandClass, 0x0F)
        XCTAssertEqual(r.commandId, 0x02)
        XCTAssertEqual(r.dataSize, 0x0C)
        XCTAssertEqual(Array(r.arguments[0..<9]), [0x01, 0x01, 0x02, 0x01, 0x28, 0x01, 0xFF, 0x00, 0x00])
    }

    func testParsesTheMouseReplies() {
        var resp = ZonedLighting.getEffect(zone: .underglow)
        for (i, b) in [0x00, 0x0A, 0x01, 0x00, 0x00, 0x01, 0x44, 0xD6, 0x2C].enumerated() { resp.arguments[i] = UInt8(b) }
        let parsed = ZonedLighting.parseEffect(resp)
        XCTAssertEqual(parsed?.effect, .staticColor)
        XCTAssertEqual(parsed?.color, RGB(r: 0x44, g: 0xD6, b: 0x2C))
        XCTAssertEqual(ZonedLighting.parse([0x03, 0x00, 0x28, 0x00, 0, 0, 0][...])?.effect, .spectrum)
        XCTAssertNil(ZonedLighting.parse([0x03, 0x00, 0x28, 0x00, 0, 0, 0][...])?.color)
        XCTAssertNil(ZonedLighting.parse([0x08, 0x00, 0x28, 0x01, 0xFF, 0, 0][...]))
    }

    func testBluetoothSendsTheSameBody() throws {
        let report = ZonedLighting.setEffect(.reactive, color: red, zone: .logo)
        let req = BLEProtocol.request(for: report, stages: nil, slot: 2, zoned: true)!
        XCTAssertEqual(req.key.bytes, [0x10, 0x03, 0x02, 0x04])
        XCTAssertEqual(req.payload, [0x05, 0x00, 0x28, 0x01, 0xFF, 0x00, 0x00, 0, 0, 0])

        let get = ZonedLighting.getEffect(zone: .scrollWheel)
        let read = BLEProtocol.request(for: get, stages: nil, slot: 1, zoned: true)!
        XCTAssertEqual(read.key.bytes, [0x10, 0x83, 0x01, 0x01])
        let resp = try BLEProtocol.response(to: get, reply: read.reply,
                                            payload: Data([0x02, 0x01, 0x28, 0x01, 0xFF, 0, 0, 0, 0, 0]))
        XCTAssertEqual(ZonedLighting.parseEffect(resp)?.effect, .breathing)
        XCTAssertEqual(ZonedLighting.parseEffect(resp)?.color, red)
    }

    func testOtherMiceKeepTheirStaticColourCommand() {
        XCTAssertEqual(BLEProtocol.request(for: RazerCommands.setStatic(rgb: red), stages: nil)?.key,
                       .staticColor)
    }
}

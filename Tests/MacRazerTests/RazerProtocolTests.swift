// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class RazerReportTests: XCTestCase {
    func testSerializedIs90BytesWithValidCRC() {
        var r = RazerReport(commandClass: 0x04, commandId: 0x05, dataSize: 0x07)
        r.transactionId = 0x1f
        r.arguments[0] = 0x01
        r.arguments[1] = 0x06
        let b = r.serialized()
        XCTAssertEqual(b.count, RazerReport.wireSize)
        XCTAssertEqual(b[88], RazerReport.crc(of: b))
        XCTAssertEqual(b[89], 0x00)
    }

    func testParseRoundTripsSerializedFields() {
        var r = RazerReport(commandClass: 0x07, commandId: 0x80, dataSize: 0x02)
        r.transactionId = 0x1f
        r.status = 0x02
        r.remainingPackets = 0x0102
        r.arguments[1] = 0xD9
        let parsed = RazerReport.parse(r.serialized())
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.status, 0x02)
        XCTAssertEqual(parsed?.transactionId, 0x1f)
        XCTAssertEqual(parsed?.remainingPackets, 0x0102)
        XCTAssertEqual(parsed?.commandClass, 0x07)
        XCTAssertEqual(parsed?.commandId, 0x80)
        XCTAssertEqual(parsed?.dataSize, 0x02)
        XCTAssertEqual(parsed?.arguments[1], 0xD9)
    }

    func testParseRejectsShortBuffer() {
        XCTAssertNil(RazerReport.parse([UInt8](repeating: 0, count: 89)))
        XCTAssertNil(RazerReport.parse([]))
    }

    func testCRCIsXorOfBytes2Through87() {
        var b = [UInt8](repeating: 0, count: 90)
        b[2] = 0xF0
        b[87] = 0x0F
        b[0] = 0xAA // outside CRC range
        b[88] = 0xAA // outside CRC range
        XCTAssertEqual(RazerReport.crc(of: b), 0xFF)
    }
}

final class RazerCommandsTests: XCTestCase {
    func testBatteryPercentScaling() {
        XCTAssertEqual(RazerCommands.batteryPercent(fromRaw: 0), 0)
        XCTAssertEqual(RazerCommands.batteryPercent(fromRaw: 255), 100)
        XCTAssertEqual(RazerCommands.batteryPercent(fromRaw: 217), 85) // observed on hardware
        XCTAssertEqual(RazerCommands.batteryPercent(fromRaw: 128), 50)
    }

    func testDPIEncodeParseRoundTrip() {
        // The response layout mirrors the set layout, so parseDPI(setDPI(...)) round-trips.
        let report = RazerCommands.setDPI(x: 1600, y: 3200)
        let dpi = RazerCommands.parseDPI(report)
        XCTAssertEqual(dpi.x, 1600)
        XCTAssertEqual(dpi.y, 3200)
        // Pin the absolute wire layout too (razer_chroma_misc_set_dpi_xy: VARSTORE,
        // x_hi, x_lo, y_hi, y_lo) — a matched offset error in both encoder and parser
        // would round-trip fine while sending the device garbage.
        XCTAssertEqual(report.commandClass, 0x04)
        XCTAssertEqual(report.commandId, 0x05)
        XCTAssertEqual(Array(report.arguments[0...4]), [0x01, 0x06, 0x40, 0x0C, 0x80])
    }

    func testSetDPIClampsRange() {
        XCTAssertEqual(RazerCommands.parseDPI(RazerCommands.setDPI(x: 50, y: 50)).x, 100)
        XCTAssertEqual(RazerCommands.parseDPI(RazerCommands.setDPI(x: 46000, y: 46000)).x, 45000)
    }

    func testParseDPIStages() {
        var resp = RazerReport(commandClass: 0x04, commandId: 0x86, dataSize: 0x26)
        resp.arguments[2] = 2 // stage count
        // stage 0 at base 4: x = 800
        resp.arguments[4] = 0x03; resp.arguments[5] = 0x20
        // stage 1 at base 11: x = 1600
        resp.arguments[11] = 0x06; resp.arguments[12] = 0x40
        XCTAssertEqual(RazerCommands.parseDPIStages(resp), [800, 1600])
    }

    func testParseDPIStagesRejectsGarbageCounts() {
        var resp = RazerReport(commandClass: 0x04, commandId: 0x86, dataSize: 0x26)
        resp.arguments[2] = 200 // implausible count from a corrupt read
        XCTAssertEqual(RazerCommands.parseDPIStages(resp), [])
        resp.arguments[2] = 0
        XCTAssertEqual(RazerCommands.parseDPIStages(resp), [])
    }

    func testParseSerial() {
        var resp = RazerReport(commandClass: 0x00, commandId: 0x82, dataSize: 0x16)
        for (i, byte) in Array("PM-2434H01234567".utf8).enumerated() { resp.arguments[i] = byte }
        XCTAssertEqual(RazerCommands.parseSerial(resp), "PM2434H01234567") // dash stripped

        var zeros = RazerReport(commandClass: 0x00, commandId: 0x82, dataSize: 0x16)
        XCTAssertNil(RazerCommands.parseSerial(zeros)) // all-zero → nil
        for i in 0..<12 { zeros.arguments[i] = UInt8(ascii: "0") }
        XCTAssertNil(RazerCommands.parseSerial(zeros)) // "000000000000" → nil
    }

    func testPollingRateMapping() {
        for (hz, code) in [(1000, UInt8(0x01)), (500, 0x02), (125, 0x08)] {
            var resp = RazerReport(commandClass: 0x00, commandId: 0x85, dataSize: 0x01)
            resp.arguments[0] = code
            XCTAssertEqual(RazerCommands.parsePollingRate(resp), hz)
            XCTAssertEqual(RazerCommands.setPollingRate(hz).arguments[0], code)
        }
        var junk = RazerReport(commandClass: 0x00, commandId: 0x85, dataSize: 0x01)
        junk.arguments[0] = 0x77
        XCTAssertEqual(RazerCommands.parsePollingRate(junk), 0)
    }

    func testBrightnessConversions() {
        XCTAssertEqual(RazerCommands.brightnessRaw(fromPercent: 0), 0)
        XCTAssertEqual(RazerCommands.brightnessRaw(fromPercent: 100), 255)
        XCTAssertEqual(RazerCommands.brightnessRaw(fromPercent: 150), 255) // clamped
        XCTAssertEqual(RazerCommands.brightnessRaw(fromPercent: -5), 0)   // clamped
        XCTAssertEqual(RazerCommands.brightnessPercent(fromRaw: 255), 100)
        XCTAssertEqual(RazerCommands.brightnessPercent(fromRaw: 0), 0)
    }
}

final class VersionCompareTests: XCTestCase {
    func testDottedIntegerComparison() {
        XCTAssertTrue(VersionCompare.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertTrue(VersionCompare.isNewer("0.2", than: "0.1.9"))
        XCTAssertTrue(VersionCompare.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertFalse(VersionCompare.isNewer("0.1.9", than: "0.1.10"))
        XCTAssertFalse(VersionCompare.isNewer("0.1.5", than: "0.1.5"))
        XCTAssertFalse(VersionCompare.isNewer("0.1", than: "0.1.0")) // trailing zero equal
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The Basilisk V4 HyperSpeed: lighting on ZERO_LED with brightness read on 0x0A, and the
/// V4 Pro's button table without the two entries this mouse keeps elsewhere.
final class BasiliskV4HyperSpeedTests: XCTestCase {
    private let dongle = 0x00EA, cable = 0x00EB

    func testLightingIsOfferedOnBothUSBLinks() {
        for pid in [dongle, cable] {
            XCTAssertTrue(RazerDevices.hasLighting(pid: pid), String(pid, radix: 16))
            XCTAssertTrue(RazerDevices.hasBrightness(pid: pid), String(pid, radix: 16))
        }
    }

    func testBrightnessIsWrittenOnZeroLedAndReadOn0x0A() {
        for pid in [dongle, cable] {
            XCTAssertEqual(RazerDevices.brightnessLeds(pid: pid), [Razer.zeroLed], String(pid, radix: 16))
            XCTAssertEqual(RazerDevices.brightnessReadLed(pid: pid), 0x0A, String(pid, radix: 16))
        }
    }

    func testOtherMiceReadBrightnessWhereTheyWriteIt() {
        // V4 Pro (logo), V3 X HyperSpeed (scroll wheel), an unknown mouse (logo fallback).
        for pid in [0x00E3, 0x00B9, 0xFFFF] {
            XCTAssertEqual(RazerDevices.brightnessReadLed(pid: pid), RazerDevices.brightnessLed(pid: pid), String(pid, radix: 16))
        }
    }

    func testDongleTableIsTheV4ProsWithoutDpiAndWheelMode() throws {
        let hyperSpeed = try XCTUnwrap(OnboardButtons.layout(pid: dongle))
        let pro = try XCTUnwrap(OnboardButtons.layout(pid: 0x00E3))
        let left = Set([HardwareButton.dpiCycle.rawValue, HardwareButton.wheelMode.rawValue])
        XCTAssertEqual(hyperSpeed, pro.filter { !left.contains($0.button) })
        XCTAssertEqual(hyperSpeed.count, 11)
        XCTAssertFalse(hyperSpeed.contains { $0.tableID == 0x60 || $0.tableID == 0x6A })
    }

    func testTheTwoSilentThumbButtonsAreRemappable() throws {
        let table = try XCTUnwrap(OnboardButtons.layout(pid: dongle))
        let trigger = try XCTUnwrap(table.first { $0.button == HardwareButton.sideTrigger.rawValue })
        let front = try XCTUnwrap(table.first { $0.button == HardwareButton.sideFront.rawValue })
        // Factory blocks as read from this mouse (SorcRR/MacRazer#135).
        XCTAssertEqual(trigger.tableID, 0x39)
        XCTAssertEqual(trigger.factory, [0x0C, 0x01, 0x39, 0, 0, 0, 0])
        XCTAssertEqual(front.tableID, 0x80)
        XCTAssertEqual(front.factory, OnboardButtons.disabledBlock)
    }

    func testRowOrderListsOnlyTheButtonsThisMouseHas() throws {
        let rows = try XCTUnwrap(OnboardButtons.rowOrder(pid: dongle))
        let table = try XCTUnwrap(OnboardButtons.layout(pid: dongle))
        XCTAssertEqual(Set(rows), Set(table.map(\.button)))
        XCTAssertEqual(rows.count, table.count)
        // The V4 Pro still lists all thirteen.
        XCTAssertEqual(OnboardButtons.rowOrder(pid: 0x00E3)?.count, 13)
    }

    func testCableAndBluetoothKeepNoTableUntilOneIsRead() {
        XCTAssertNil(OnboardButtons.layout(pid: cable))
        XCTAssertNil(OnboardButtons.layout(pid: 0x00EC))
    }

    // MARK: Polling (00:0E / 00:8E, openrazer/openrazer#2959)

    func testPollingReadIs008EWithVarstore() {
        let read = RazerCommands.pollingRateRead(command: .basiliskV4HyperSpeed).report
        XCTAssertEqual(read.commandClass, 0x00)
        XCTAssertEqual(read.commandId, 0x8E)
        XCTAssertEqual(read.dataSize, 0x02)
        XCTAssertEqual(read.arguments[0], 0x01)
    }

    func testPollingWriteIsOne000ECommandWithClassicCodes() {
        for (hz, code) in [(1000, UInt8(0x01)), (500, 0x02), (125, 0x08)] {
            let reports = RazerCommands.setPollingRateReports(hz, command: .basiliskV4HyperSpeed)
            XCTAssertEqual(reports.count, 1, "\(hz)")
            XCTAssertEqual(reports[0].commandClass, 0x00)
            XCTAssertEqual(reports[0].commandId, 0x0E)
            XCTAssertEqual(reports[0].dataSize, 0x02)
            XCTAssertEqual(Array(reports[0].arguments[0...1]), [0x01, code], "\(hz)")
        }
        // A rate this mouse lacks falls back to 1000 Hz.
        XCTAssertEqual(RazerCommands.setPollingRateV4HyperSpeed(250).arguments[1], 0x01)
    }

    func testPollingAnswerDecodesTheSecondArgument() {
        var resp = RazerReport(commandClass: 0x00, commandId: 0x8E, dataSize: 0x02)
        resp.arguments[0] = 0x01
        for (code, hz) in [(UInt8(0x01), 1000), (0x02, 500), (0x08, 125), (0x04, 0)] {
            resp.arguments[1] = code
            XCTAssertEqual(RazerCommands.parsePollingRateV4HyperSpeed(resp), hz, "code \(code)")
        }
    }

    func testOtherCommandsAreUnchanged() {
        XCTAssertEqual(RazerCommands.setPollingRateReports(1000, command: .classic).map(\.commandId), [0x05])
        XCTAssertEqual(RazerCommands.setPollingRateReports(1000, command: .rate2).map(\.commandId), [0x40, 0x40])
        XCTAssertEqual(RazerCommands.pollingRateRead(command: .rate2).report.commandId, 0xC0)
        XCTAssertEqual(RazerCommands.pollingRateRead(command: .classic).report.commandId, 0x85)
    }

    func testNoSlotsMeansNoFactoryRestore() {
        XCTAssertFalse(RazerDevices.hasOnboardSlots(pid: dongle))
        XCTAssertTrue(OnboardSlots.factorySettings(pid: dongle).isEmpty)
    }
}

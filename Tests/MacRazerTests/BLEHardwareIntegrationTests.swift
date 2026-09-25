// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// Opt-in test for the user's paired Basilisk. It only writes the currently active DPI value.
/// Run with MACRAZER_BLE_HARDWARE_TEST=1 swift test --filter BLEHardwareIntegrationTests.
final class BLEHardwareIntegrationTests: XCTestCase {
    func testReadBatteryAndDpiAfterMouseSleepInterval() throws {
        guard ProcessInfo.processInfo.environment["MACRAZER_BLE_HARDWARE_TEST"] == "1" else {
            throw XCTSkip("Set MACRAZER_BLE_HARDWARE_TEST=1 to use a paired Basilisk V3 X HyperSpeed.")
        }
        let device = try BluetoothDevice.open(productName: "BSK V3 X HS")
        defer { device.close() }

        let timeout = try device.readSleepTimeoutSeconds()
        XCTAssertGreaterThan(timeout, 0)
        print("[BLE hardware] leaving mouse untouched for its reported \(timeout)-second sleep timeout")
        Thread.sleep(forTimeInterval: TimeInterval(timeout) + 15)

        let battery = try device.sendWithRetry(RazerCommands.getBatteryLevel())
        let percent = Int((Double(battery.arguments[1]) * 100 / 255).rounded())
        XCTAssertTrue((0...100).contains(percent))

        let stagesReport = try device.sendWithRetry(RazerCommands.getDPIStages())
        let stages = RazerCommands.parseDPIStages(stagesReport)
        let active = RazerCommands.parseActiveDPIStage(stagesReport)
        XCTAssertTrue(stages.indices.contains(active))
        let dpi = RazerCommands.parseDPI(try device.sendWithRetry(RazerCommands.getDPI())).x
        XCTAssertEqual(dpi, UInt16(stages[active]))
    }

    func testReadBatteryStagesAndRoundTripCurrentDpi() throws {
        guard ProcessInfo.processInfo.environment["MACRAZER_BLE_HARDWARE_TEST"] == "1" else {
            throw XCTSkip("Set MACRAZER_BLE_HARDWARE_TEST=1 to use a paired Basilisk V3 X HyperSpeed.")
        }
        // Scan the model's vendor GATT service directly. The HID mouse can be asleep or not
        // enumerated while the Mac is locked, which must not prevent testing the control link.
        let device = try BluetoothDevice.open(productName: "BSK V3 X HS")
        defer { device.close() }

        let sleepTimeout = try device.readSleepTimeoutSeconds()
        XCTAssertGreaterThan(sleepTimeout, 0)
        print("[BLE hardware] current mouse sleep timeout: \(sleepTimeout) seconds (read only)")

        let battery = try device.sendWithRetry(RazerCommands.getBatteryLevel())
        let percent = Int((Double(battery.arguments[1]) * 100 / 255).rounded())
        XCTAssertTrue((0...100).contains(percent), "Battery response must decode to a percentage")

        let dpiCycleBinding = try device.readDpiCycleBinding()
        print("[BLE hardware] DPI Cycle button assignment: \(dpiCycleBinding.label)")

        let brightness = try device.sendWithRetry(RazerCommands.getBrightness(led: 0x01))
        XCTAssertEqual(brightness.status, 0x02, "Brightness GATT read must succeed")
        XCTAssertTrue((0...100).contains(RazerCommands.brightnessPercent(fromRaw: brightness.arguments[2])))

        let stagesReport = try device.sendWithRetry(RazerCommands.getDPIStages())
        let stages = RazerCommands.parseDPIStages(stagesReport)
        let active = RazerCommands.parseActiveDPIStage(stagesReport)
        XCTAssertFalse(stages.isEmpty)
        XCTAssertTrue(stages.indices.contains(active))

        let current = RazerCommands.parseDPI(try device.sendWithRetry(RazerCommands.getDPI())).x
        XCTAssertEqual(current, UInt16(stages[active]))
        print("[BLE hardware] active DPI: \(current); stages: \(stages); active stage index: \(active)")

        // The transport itself performs a BLE readback before reporting this write as success.
        _ = try device.sendWithRetry(RazerCommands.setDPI(x: current, y: current))
        let independentlyRead = RazerCommands.parseDPI(try device.sendWithRetry(RazerCommands.getDPI())).x
        XCTAssertEqual(independentlyRead, current)

        // Exercise a real BLE close/reopen as a separate check from the protocol fixtures.
        device.close()
        Thread.sleep(forTimeInterval: 0.3)
        let reconnected = try BluetoothDevice.open(productName: "BSK V3 X HS")
        defer { reconnected.close() }
        let reconnectedBattery = try reconnected.sendWithRetry(RazerCommands.getBatteryLevel())
        let reconnectedPercent = Int((Double(reconnectedBattery.arguments[1]) * 100 / 255).rounded())
        XCTAssertTrue((0...100).contains(reconnectedPercent))
        let reconnectedDpi = RazerCommands.parseDPI(try reconnected.sendWithRetry(RazerCommands.getDPI())).x
        XCTAssertEqual(reconnectedDpi, current)
    }

    func testReadAndRoundTripCurrentDpiCycleButtonBinding() throws {
        guard ProcessInfo.processInfo.environment["MACRAZER_BLE_HARDWARE_TEST"] == "1" else {
            throw XCTSkip("Set MACRAZER_BLE_HARDWARE_TEST=1 to use a paired Basilisk V3 X HyperSpeed.")
        }
        let device = try BluetoothDevice.open(productName: "BSK V3 X HS")
        defer { device.close() }

        let dpiBefore = RazerCommands.parseDPI(try device.sendWithRetry(RazerCommands.getDPI())).x
        let original = try device.readDpiCycleBinding()
        try device.setDpiCycleBinding(original)
        let restored = try device.readDpiCycleBinding()
        XCTAssertEqual(restored, original,
                       "Writing the existing DPI Cycle assignment must preserve its readback")
        let dpiAfter = RazerCommands.parseDPI(try device.sendWithRetry(RazerCommands.getDPI())).x
        XCTAssertEqual(dpiAfter, dpiBefore,
                       "Writing the existing DPI Cycle assignment must not change the active DPI")
        print("[BLE hardware] DPI Cycle assignment write/readback: \(restored.label)")
        print("[BLE hardware] active DPI before/after button write: \(dpiBefore)/\(dpiAfter)")
    }
}

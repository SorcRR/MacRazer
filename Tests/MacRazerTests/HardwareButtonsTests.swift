// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class HardwareButtonsTests: XCTestCase {
    func testIdsCannotCollideWithMouseButtonsOrTheBluetoothDpiCycle() {
        for button in HardwareButton.allCases {
            XCTAssertLessThan(button.rawValue, -1)
            XCTAssertEqual(ButtonRemapper.label(for: button.rawValue), button.label)
        }
    }

    // MARK: Wheel mode

    func testWheelModeCommandsAsMeasured() {
        let get = RazerCommands.getWheelMode()
        XCTAssertEqual([get.commandClass, get.commandId, get.dataSize, get.arguments[0]], [0x02, 0xB0, 0x02, 0x01])
        let set = RazerCommands.setWheelMode(0x02)
        XCTAssertEqual([set.commandClass, set.commandId, set.dataSize], [0x02, 0x30, 0x02])
        XCTAssertEqual(Array(set.arguments.prefix(2)), [0x01, 0x02])
    }

    func testSmartReelSetMatchesOpenRazer() {
        // razer_chroma_misc_set_scroll_smart_reel; accepted by the V4 Pro (read back 01 01).
        let on = RazerCommands.setScrollSmartReel(true)
        XCTAssertEqual([on.commandClass, on.commandId, on.dataSize], [0x02, 0x17, 0x02])
        XCTAssertEqual(Array(on.arguments.prefix(2)), [0x01, 0x01])
        XCTAssertEqual(RazerCommands.setScrollSmartReel(false).arguments[1], 0x00)
    }

    func testSmartReelSensitivityCommands() {
        // Found on the V4 Pro: 0x02/0xA3 reads, 0x02/0x23 writes, 0-4 (5 refused with 0x03).
        let get = RazerCommands.getSmartReelSensitivity()
        XCTAssertEqual([get.commandClass, get.commandId, get.dataSize, get.arguments[0]], [0x02, 0xA3, 0x02, Razer.varstore])
        let set = RazerCommands.setSmartReelSensitivity(4)
        XCTAssertEqual([set.commandClass, set.commandId, set.dataSize], [0x02, 0x23, 0x02])
        XCTAssertEqual(Array(set.arguments.prefix(2)), [0x01, 0x04])
        XCTAssertEqual(RazerCommands.setSmartReelSensitivity(9).arguments[1], 0x04, "clamped to what the mouse takes")
        var reply = RazerReport(commandClass: 0x02, commandId: 0xA3, dataSize: 0x02)
        reply.arguments[0] = 0x01
        reply.arguments[1] = 0x02
        XCTAssertEqual(RazerCommands.parseWheelLevel(reply), 2)
        reply.arguments[1] = 0x05
        XCTAssertNil(RazerCommands.parseWheelLevel(reply))
    }

    func testScrollAccelerationCommands() {
        // razer_chroma_misc_{get,set}_scroll_acceleration; the level is 0x02/0xA2 and 0x02/0x22.
        let get = RazerCommands.getScrollAcceleration()
        XCTAssertEqual([get.commandClass, get.commandId, get.dataSize, get.arguments[0]], [0x02, 0x96, 0x02, Razer.varstore])
        let on = RazerCommands.setScrollAcceleration(true)
        XCTAssertEqual([on.commandClass, on.commandId, on.dataSize], [0x02, 0x16, 0x02])
        XCTAssertEqual(Array(on.arguments.prefix(2)), [0x01, 0x01])
        XCTAssertEqual(RazerCommands.setScrollAcceleration(false).arguments[1], 0x00)
        let level = RazerCommands.getScrollAccelerationLevel()
        XCTAssertEqual([level.commandClass, level.commandId, level.arguments[0]], [0x02, 0xA2, Razer.varstore])
        let set = RazerCommands.setScrollAccelerationLevel(0)
        XCTAssertEqual([set.commandClass, set.commandId, set.dataSize, set.arguments[0], set.arguments[1]], [0x02, 0x22, 0x02, 0x01, 0x00])
        XCTAssertEqual(RazerCommands.setScrollAccelerationLevel(-1).arguments[1], 0x00)
    }

    func testSmartReelAndPollingRate2ReadsMatchOpenRazer() {
        let reel = RazerCommands.getScrollSmartReel()
        XCTAssertEqual([reel.commandClass, reel.commandId, reel.dataSize, reel.arguments[0]], [0x02, 0x97, 0x02, Razer.varstore])
        let poll2 = RazerCommands.getPollingRate2()
        XCTAssertEqual([poll2.commandClass, poll2.commandId, poll2.dataSize], [0x00, 0xC0, 0x01])
    }
}

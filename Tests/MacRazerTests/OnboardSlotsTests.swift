// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class OnboardSlotsTests: XCTestCase {
    func testSettingsCommandsFollowTheSlot() {
        XCTAssertEqual(OnboardSlots.retarget(RazerCommands.getDPI(), to: 3).arguments[0], 3)
        XCTAssertEqual(OnboardSlots.retarget(RazerCommands.setButtonFunction(0x01, block: [1, 1, 1]), to: 2).arguments[0], 2)
        XCTAssertEqual(OnboardSlots.retarget(RazerCommands.getDPI(), to: 1).arguments[0], 1)
    }

    func testOtherCommandsAreLeftAlone() {
        // Battery level and the slot commands themselves carry no slot.
        XCTAssertEqual(OnboardSlots.retarget(RazerCommands.getBatteryLevel(), to: 4).arguments[0], 0)
        XCTAssertEqual(OnboardSlots.retarget(OnboardSlots.activate(1), to: 4).arguments[0], 1)
    }

    func testParsesTheSlotList() {
        var r = OnboardSlots.listSlots()
        r.dataSize = 3
        r.arguments[0] = 5; r.arguments[1] = 1; r.arguments[2] = 2
        XCTAssertEqual(OnboardSlots.parseSlots(r), [1, 2])
        r.arguments[1] = 0; r.arguments[2] = 0
        XCTAssertNil(OnboardSlots.parseSlots(r))
    }

    func testPicksASlot() {
        let a = UUID(), b = UUID(), c = UUID()
        // The first profile takes the slot the mouse is on.
        XCTAssertEqual(OnboardSlots.slot(for: a, assigned: [:], active: 1), 1)
        // Its own slot always wins.
        XCTAssertEqual(OnboardSlots.slot(for: a, assigned: [a: 3], active: 1), 3)
        // Otherwise the lowest free one.
        XCTAssertEqual(OnboardSlots.slot(for: c, assigned: [a: 1, b: 3], active: 1), 2)
        let full = Dictionary(uniqueKeysWithValues: (1...5).map { (UUID(), $0) })
        XCTAssertNil(OnboardSlots.slot(for: c, assigned: full, active: 1))
    }

    func testCycleProfileBlocks() {
        XCTAssertEqual(OnboardButtons.nativeBlock(for: .cycleProfile(up: true)), [0x07, 0x01, 0x04, 0, 0, 0, 0])
        XCTAssertEqual(OnboardButtons.nativeBlock(for: .cycleProfile(up: false)), [0x07, 0x01, 0x05, 0, 0, 0, 0])
    }

    // MARK: Slots are the profiles

    func testANewProfileGoesInTheLowestFreeSlot() {
        XCTAssertEqual(OnboardSlots.nextFreeSlot(existing: [1]), 2)
        XCTAssertEqual(OnboardSlots.nextFreeSlot(existing: [1, 2, 4]), 3)
        XCTAssertNil(OnboardSlots.nextFreeSlot(existing: [1, 2, 3, 4, 5]), "all five are used")
    }

    func testFactorySettingsAreTheBytesReadFromUntouchedSlots() {
        let reports = OnboardSlots.factorySettings(pid: 0x00E3)
        func find(_ commandClass: UInt8, _ id: UInt8, _ arg1: UInt8? = nil) -> RazerReport? {
            reports.first { $0.commandClass == commandClass && $0.commandId == id && (arg1 == nil || $0.arguments[1] == arg1) }
        }
        // Slots 3-5 of the V4 Pro, read on 2026-10-22 (after the slot byte).
        let stages: [UInt8] = [0x03, 0x05, 0x01, 0x01, 0x90, 0x01, 0x90, 0x01, 0x90, 0x02, 0x03, 0x20, 0x03, 0x20, 0x03, 0x20,
                               0x03, 0x06, 0x40, 0x06, 0x40, 0x06, 0x40, 0x04, 0x0C, 0x80, 0x0C, 0x80, 0x0C, 0x80,
                               0x05, 0x19, 0x00, 0x19, 0x00, 0x19, 0x00]
        XCTAssertEqual(Array(find(0x04, 0x06)!.arguments[1...stages.count]), stages)
        XCTAssertEqual(Array(find(0x04, 0x05)!.arguments[1...4]), [0x06, 0x40, 0x06, 0x40], "1600 DPI")
        for zone: UInt8 in [0x01, 0x04, 0x0A] {
            XCTAssertEqual(Array(find(0x0F, 0x02, zone)!.arguments[2..<12]), [0x03, 0x01, 0x28, 0x01, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00])
            XCTAssertEqual(find(0x0F, 0x04, zone)!.arguments[2], 0x55)
        }
        XCTAssertEqual(find(0x02, 0x17)!.arguments[1], 0x00, "Smart-Reel off")
        XCTAssertTrue(reports.allSatisfy { $0.arguments[0] == OnboardSlots.first }, "addressed to slot 1, retargeted to the slot")
        XCTAssertTrue(reports.allSatisfy { OnboardSlots.retarget($0, to: 4).arguments[0] == 4 }, "every one follows the slot")
    }

    func testFactorySettingsOverBluetoothSkipWhatThatLinkHasNoCommandFor() {
        let reports = OnboardSlots.factorySettings(pid: 0x00E4)
        XCTAssertFalse(reports.contains { $0.commandClass == 0x04 && $0.commandId == 0x05 }, "the stage table sets the DPI")
        XCTAssertFalse(reports.contains { $0.commandClass == 0x02 }, "no Smart-Reel over Bluetooth")
        let stages = reports.first { $0.commandClass == 0x04 && $0.commandId == 0x06 }!
        XCTAssertEqual(stages.arguments[1], 0x02, "stage 3 of 5, counted from 0")
        XCTAssertNotNil(BLEProtocol.request(for: stages, stages: nil, slot: 2, zoned: true))
        for report in reports {
            XCTAssertNotNil(BLEProtocol.request(for: report, stages: nil, slot: 2, zoned: true), "every one has a Bluetooth form")
        }
        XCTAssertTrue(OnboardSlots.factorySettings(pid: 0x00B9).isEmpty, "a mouse without a table has no factory slot")
    }

    func testProfileNamesDefaultToTheirSlotAndCarryOverSnapshotNames() {
        let key = "MacRazerTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "slotNames-\(key)") }
        XCTAssertEqual(SlotNames.defaultName(3), "Profile 3")
        var work = MouseProfile(name: "Work", dpi: 1600, pollRate: 1000, brightness: 50, effect: "", color: RGB(r: 0, g: 0, b: 0), buttonMappings: [:])
        work.onboardSlot = 2
        let loose = MouseProfile(name: "Loose", dpi: 800, pollRate: 1000, brightness: 50, effect: "", color: RGB(r: 0, g: 0, b: 0), buttonMappings: [:])
        XCTAssertEqual(SlotNames.names(forDevice: key, carrying: [work, loose]), [2: "Work"])
        SlotNames.save([2: "Games", 4: "Photo"], forDevice: key)
        XCTAssertEqual(SlotNames.names(forDevice: key, carrying: [work]), [2: "Games", 4: "Photo"], "a saved name wins")
    }
}

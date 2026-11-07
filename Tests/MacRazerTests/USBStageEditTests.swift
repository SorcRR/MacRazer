// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// Editing the DPI stage table over the dongle or cable.
final class USBStageEditTests: XCTestCase {
    /// The Basilisk V4 HyperSpeed's reply from a 0.6.1 report: stages numbered from 1, the
    /// active byte naming stage 2 (4000), the DPI the mouse was on.
    private func basiliskReply() -> RazerReport {
        var r = RazerCommands.setDPIStages([2000, 4000, 5000, 6000, 7000], activeStage: 0)
        r.commandId = 0x86
        r.arguments[1] = 2
        for i in 0..<5 { r.arguments[3 + i * 7] = UInt8(i + 1) }
        return r
    }

    func testTheTableKeepsTheMousesOwnStageNumbers() throws {
        let table = try XCTUnwrap(RazerCommands.parseDPIStageTable(basiliskReply()))
        XCTAssertEqual(table.ids, [1, 2, 3, 4, 5])
        XCTAssertEqual(table.values, [2000, 4000, 5000, 6000, 7000])
        XCTAssertEqual(table.activeIndex, 1, "active byte 2 is the second stage, not the third")
    }

    func testWritingBackRoundTripsTheReply() throws {
        let reply = basiliskReply()
        let table = try XCTUnwrap(RazerCommands.parseDPIStageTable(reply))
        let write = RazerCommands.setDPIStages(table)
        XCTAssertEqual(write.commandId, 0x06)
        XCTAssertEqual(Array(write.arguments[0..<38]), Array(reply.arguments[0..<38]))
    }

    func testABrokenTableIsRejected() {
        var r = basiliskReply()
        r.arguments[2] = 0
        XCTAssertNil(RazerCommands.parseDPIStageTable(r), "no stages")
        r = basiliskReply()
        r.arguments[2] = 9
        XCTAssertNil(RazerCommands.parseDPIStageTable(r), "more than the report holds")
        r = basiliskReply()
        r.arguments[3 + 7 + 1] = 0; r.arguments[3 + 7 + 2] = 0
        XCTAssertNil(RazerCommands.parseDPIStageTable(r), "a zero stage would shift the indices")
    }

    func testEditingOneStageWritesOnlyThatStage() throws {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setDPIStages(try XCTUnwrap(RazerCommands.parseDPIStageTable(basiliskReply()))))
        let written = try MouseController.writeUSBStages(send: { try mouse.sendWithRetry($0, attempts: 1) }) {
            $0.values[1] = 4500
        }
        XCTAssertEqual(written.values, [2000, 4500, 5000, 6000, 7000])
        XCTAssertEqual(written.activeIndex, 1, "the active stage stays where the mouse had it")
        XCTAssertEqual(written.ids, [1, 2, 3, 4, 5])
    }

    func testSelectingAStageMakesItActive() throws {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setDPIStages(try XCTUnwrap(RazerCommands.parseDPIStageTable(basiliskReply()))))
        let written = try MouseController.writeUSBStages(send: { try mouse.sendWithRetry($0, attempts: 1) }) {
            $0.activeID = $0.ids[3]
        }
        XCTAssertEqual(written.activeIndex, 3)
        XCTAssertEqual(written.activeID, 4)
    }

    func testAReadBackThatDiffersFails() throws {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setDPIStages(try XCTUnwrap(RazerCommands.parseDPIStageTable(basiliskReply()))))
        // The mouse keeps its own stage 2 whatever is written.
        mouse.clamp = { report in
            guard report.commandId == 0x06 else { return report }
            var kept = report
            kept.arguments[3 + 7 + 1] = 0x0F; kept.arguments[3 + 7 + 2] = 0xA0
            return kept
        }
        XCTAssertThrowsError(try MouseController.writeUSBStages(send: { try mouse.sendWithRetry($0, attempts: 1) }) {
            $0.values[1] = 4500
        })
    }

    func testFirmwareRoundingStillCountsAsKept() throws {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setDPIStages(try XCTUnwrap(RazerCommands.parseDPIStageTable(basiliskReply()))))
        // Stage 2 lands as 4300 when 4321 is written.
        mouse.clamp = { report in
            guard report.commandId == 0x06 else { return report }
            var kept = report
            kept.arguments[3 + 7 + 1] = 0x10; kept.arguments[3 + 7 + 2] = 0xCC
            return kept
        }
        let written = try MouseController.writeUSBStages(send: { try mouse.sendWithRetry($0, attempts: 1) }) {
            $0.values[1] = 4321
        }
        XCTAssertEqual(written.values[1], 4300)
    }

    func testOnlyUSBRowsWithVerifiedDPIGetTheEditor() {
        XCTAssertTrue(RazerDevices.supportsUSBStageEditing(pid: 0x00EA), "Basilisk V4 HyperSpeed dongle")
        XCTAssertTrue(RazerDevices.supportsUSBStageEditing(pid: 0x00DB), "Cobra HyperSpeed dongle")
        XCTAssertFalse(RazerDevices.supportsUSBStageEditing(pid: 0x00DC), "Bluetooth has its own path")
        XCTAssertFalse(RazerDevices.supportsUSBStageEditing(pid: 0x006E), "DeathAdder Essential (2018): DPI unverified")
        XCTAssertFalse(RazerDevices.supportsUSBStageEditing(pid: 0x9999))
    }
}

/// The stage editor's limits: digits only, and between the stages either side.
final class StageEditorLimitTests: XCTestCase {
    let stages = [400, 800, 1600, 3200, 6400]

    func testAStageStaysBetweenItsNeighbours() {
        XCTAssertEqual(PopoverView.stageRange(stages: stages, index: 2, maxDPI: 26000), 850...3150)
        XCTAssertEqual(PopoverView.stageRange(stages: stages, index: 0, maxDPI: 26000), 100...750, "the first starts at 100")
        XCTAssertEqual(PopoverView.stageRange(stages: stages, index: 4, maxDPI: 26000), 3250...26000, "the last goes to the max")
    }

    func testAHemmedInStageKeepsItsValue() {
        XCTAssertEqual(PopoverView.stageRange(stages: [800, 820, 840], index: 1, maxDPI: 26000), 820...820)
    }

    func testAnUnsortedTableOnlyUsesNeighboursInOrder() {
        let mixed = [1600, 800, 3200, 6400, 400]
        XCTAssertEqual(PopoverView.stageRange(stages: mixed, index: 1, maxDPI: 26000), 100...3150,
                       "1600 before 800 bounds nothing; 3200 after still does")
        XCTAssertEqual(PopoverView.stageRange(stages: mixed, index: 3, maxDPI: 26000), 3250...26000)
    }

    func testOnlyDigitsAreTyped() {
        XCTAssertEqual(PopoverView.digitsOnly("1,6a00 ", maxDPI: 26000), "1600")
        XCTAssertEqual(PopoverView.digitsOnly("123456", maxDPI: 26000), "12345", "no more digits than the max has")
        XCTAssertEqual(PopoverView.digitsOnly("١٢٣", maxDPI: 26000), "", "non-ASCII digits don't parse as Int")
    }
}

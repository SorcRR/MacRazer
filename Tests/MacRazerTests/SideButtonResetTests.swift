// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The rows come from a Cobra HyperSpeed over Bluetooth (0x00DC) whose side buttons Synapse
/// had set to Ctrl+V and Ctrl+C (a Report an Issue on 0.9.0). The report keeps only the first
/// 12 bytes of each reply and the parser needs 16, so the rest is padded with zeros: the
/// missing bytes are the blocks' last two bytes, zero in every block read so far.
final class SideButtonResetTests: XCTestCase {
    private func reply(_ first12: [UInt8]) -> Data { Data(first12 + [0, 0, 0, 0]) }

    private let back = [UInt8]([4, 0, 2, 1, 2, 1, 1, 4, 25, 0, 0, 0])
    private let forward = [UInt8]([5, 0, 2, 1, 2, 1, 1, 5, 6, 0, 0, 0])
    private let leftClick = [UInt8]([1, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0])

    func testTheReportedRowsReadAsCtrlVAndCtrlCOverTheSideButtons() throws {
        let function = try BLEProtocol.parseButtonFunction(id: 4, reply(back))
        XCTAssertEqual(function.current, [0x02, 0x02, 0x01, 0x19, 0, 0, 0])
        XCTAssertEqual(function.factory, [0x01, 0x01, 0x04, 0, 0, 0, 0])

        let remaps = [SideButtonReset.remap(id: 4, payload: reply(back)),
                      SideButtonReset.remap(id: 5, payload: reply(forward))].compactMap { $0 }
        XCTAssertEqual(remaps.map(\.id), [4, 5])
        XCTAssertEqual(remaps.map(\.factory), [SideButtonReset.mouseBlock(4), SideButtonReset.mouseBlock(5)])
        XCTAssertEqual(remaps.map { SideButtonReset.describe($0.current) }, ["⌃V", "⌃C"])
    }

    func testAButtonOnItsFactoryFunctionIsNoRemap() {
        XCTAssertNil(SideButtonReset.remap(id: 4, payload: reply([4, 0, 1, 1, 1, 1, 4, 4, 0, 0, 0, 0])))
    }

    func testOnlyTheSideButtonsAreOffered() {
        XCTAssertNil(SideButtonReset.remap(id: 1, payload: reply(leftClick)))
    }

    func testAHyperShiftFlagIsNotReadAsAFactoryBlock() {
        var shifted = back
        shifted[1] = 0x01
        XCTAssertNil(SideButtonReset.remap(id: 4, payload: reply(shifted)))
    }

    func testAFactoryBlockThatIsNotTheButtonItselfIsLeftAlone() {
        // Factory block 01 01 05 on entry 4: not the layout this was read from.
        XCTAssertNil(SideButtonReset.remap(id: 4, payload: reply([4, 0, 2, 1, 2, 1, 1, 5, 25, 0, 0, 0])))
    }

    func testAShortOrMismatchedReplyIsNoRemap() {
        XCTAssertNil(SideButtonReset.remap(id: 4, payload: Data(back)))
        XCTAssertNil(SideButtonReset.remap(id: 5, payload: reply(back)))
    }

    func testAMacroStillCountsWithoutALabel() throws {
        // Type 05 (a macro) on Back: offered, but not described.
        let remap = try XCTUnwrap(SideButtonReset.remap(id: 4, payload: reply([4, 0, 5, 1, 1, 1, 7, 4, 0, 0, 0, 0])))
        XCTAssertNil(SideButtonReset.describe(remap.current))
        XCTAssertTrue(SideButtonReset.noticeText([remap]).contains("Back does something else"))
    }

    func testSwappedButtonsAndALoneModifierAreDescribedHonestly() throws {
        let swapped = try XCTUnwrap(SideButtonReset.remap(id: 4, payload: reply([4, 0, 1, 1, 1, 1, 5, 4, 0, 0, 0, 0])))
        XCTAssertEqual(SideButtonReset.describe(swapped.current), "Forward")
        XCTAssertFalse(SideButtonReset.noticeText([swapped]).contains("mouse buttons"))
        XCTAssertNil(SideButtonReset.describe([0x02, 0x02, 0x01, 0x00, 0, 0, 0]))
    }

    private var factoryBack: [UInt8] { [4, 0, 1, 1, 1, 1, 4, 4, 0, 0, 0, 0] }

    func testASlotHoldsTheRemapOnlyWhenItsReadMatchesExactly() throws {
        let remap = try XCTUnwrap(SideButtonReset.remap(id: 4, payload: reply(back)))
        XCTAssertTrue(SideButtonReset.slotHolds(remap, slotPayload: reply(back)))
        XCTAssertFalse(SideButtonReset.slotHolds(remap, slotPayload: reply(factoryBack)))
        // Ctrl+X instead of Ctrl+V: one byte off.
        XCTAssertFalse(SideButtonReset.slotHolds(remap, slotPayload: reply([4, 0, 2, 1, 2, 1, 1, 4, 27, 0, 0, 0])))
        // Another entry's reply, or one too short to read.
        XCTAssertFalse(SideButtonReset.slotHolds(remap, slotPayload: reply(forward)))
        XCTAssertFalse(SideButtonReset.slotHolds(remap, slotPayload: Data(back)))
        XCTAssertEqual(BLEProtocol.Key.buttonFunctionGet(4, slot: 2).bytes, [0x08, 0x84, 0x02, 0x04])
    }

    func testTheSameRemapInEverySlotResetsEverySlot() throws {
        let remap = try XCTUnwrap(SideButtonReset.remap(id: 4, payload: reply(back)))
        let reads = Dictionary(uniqueKeysWithValues: SideButtonReset.slots.map { ($0, reply(back)) })
        // Whatever slot 03/82 names, even a wrong one, every slot holding it is written.
        XCTAssertEqual(try SideButtonReset.slotsToReset(remap, activeSlot: 2, slotPayloads: reads), [1, 2, 3, 4, 5])
        XCTAssertEqual(try SideButtonReset.slotsToReset(remap, activeSlot: 1, slotPayloads: reads), [1, 2, 3, 4, 5])
        // Three of five hold it, one holds something else: only the three.
        let some: [UInt8: Data] = [1: reply(back), 2: reply(factoryBack), 3: reply(back), 4: reply(back),
                                   5: reply([4, 0, 2, 1, 2, 1, 1, 4, 27, 0, 0, 0])]
        XCTAssertEqual(try SideButtonReset.slotsToReset(remap, activeSlot: 3, slotPayloads: some), [1, 3, 4])
        XCTAssertEqual(SideButtonReset.doneText(profiles: 3), "Side buttons reset on all 3 profiles that had the remap.")
    }

    func testTheRemapOnlyInTheReportedSlotResetsThatSlot() throws {
        let remap = try XCTUnwrap(SideButtonReset.remap(id: 4, payload: reply(back)))
        let reads: [UInt8: Data] = [1: reply(factoryBack), 2: reply(back), 3: reply(factoryBack)]
        XCTAssertEqual(try SideButtonReset.slotsToReset(remap, activeSlot: 2, slotPayloads: reads), [2])
        XCTAssertEqual(SideButtonReset.doneText(profiles: 1), "Side buttons reset.")
    }

    func testTheRemapOnlyInAnotherSlotWritesNothing() throws {
        let remap = try XCTUnwrap(SideButtonReset.remap(id: 4, payload: reply(back)))
        let reads: [UInt8: Data] = [1: reply(factoryBack), 2: reply(factoryBack), 3: reply(back)]
        XCTAssertThrowsError(try SideButtonReset.slotsToReset(remap, activeSlot: 1, slotPayloads: reads)) {
            XCTAssertEqual($0 as? SideButtonReset.ResetError, .slotUnconfirmed)
        }
        // The named slot refused its read: the same.
        XCTAssertThrowsError(try SideButtonReset.slotsToReset(remap, activeSlot: 1, slotPayloads: [3: reply(back)])) {
            XCTAssertEqual($0 as? SideButtonReset.ResetError, .slotUnconfirmed)
        }
    }

    func testTheRemapInNoSlotWritesNothing() throws {
        let remap = try XCTUnwrap(SideButtonReset.remap(id: 4, payload: reply(back)))
        XCTAssertThrowsError(try SideButtonReset.slotsToReset(remap, activeSlot: 1, slotPayloads: [1: reply(factoryBack)])) {
            XCTAssertEqual($0 as? SideButtonReset.ResetError, .notInAnySlot)
        }
        XCTAssertThrowsError(try SideButtonReset.slotsToReset(remap, activeSlot: 1, slotPayloads: [:])) {
            XCTAssertEqual($0 as? SideButtonReset.ResetError, .notInAnySlot)
        }
    }

    func testFailuresReadAsPlainSentences() {
        let errors: [Error] = [SideButtonReset.ResetError.slotUnconfirmed, SideButtonReset.ResetError.notInAnySlot,
                               SideButtonReset.ResetError.notReadBack, SideButtonReset.ResetError.partlyWritten,
                               HIDDevice.HIDError.timeout, HIDDevice.HIDError.commandFailed]
        for error in errors {
            let text = SideButtonReset.failureText(error)
            XCTAssertFalse(text.contains("operation couldn"), text)
            XCTAssertFalse(text.contains("status 0x"), text)
            XCTAssertFalse(text.contains("—"), text)
        }
        XCTAssertTrue(SideButtonReset.failureText(SideButtonReset.ResetError.slotUnconfirmed).contains("changed nothing"))
        XCTAssertTrue(SideButtonReset.failureText(SideButtonReset.ResetError.notInAnySlot).contains("changed nothing"))
        XCTAssertFalse(SideButtonReset.doneText(profiles: 3).contains("—"))
    }

    func testTheResetWriteIsTheFactoryBlockInTheActiveSlot() {
        XCTAssertEqual(BLEProtocol.Key.buttonFunctionSet(4, slot: 2).bytes, [0x08, 0x04, 0x02, 0x04])
        XCTAssertEqual(BLEProtocol.buttonFunctionPayload(id: 4, block: SideButtonReset.mouseBlock(4), slot: 2),
                       [0x02, 0x04, 0x00, 0x01, 0x01, 0x04, 0, 0, 0, 0])
        XCTAssertEqual(BLEProtocol.Key.buttonFunctionGet(5).bytes, [0x08, 0x84, 0x00, 0x05])
    }

    func testTheNoticeNamesBothButtons() {
        let remaps = [SideButtonReset.remap(id: 4, payload: reply(back)),
                      SideButtonReset.remap(id: 5, payload: reply(forward))].compactMap { $0 }
        let text = SideButtonReset.noticeText(remaps)
        XCTAssertTrue(text.contains("Back sends ⌃V and Forward sends ⌃C"), text)
        XCTAssertTrue(text.contains("until they're reset"))
        XCTAssertFalse(text.contains("—"))
    }

    func testOnlyTheCobraOverBluetoothIsChecked() {
        XCTAssertTrue(RazerDevices.detectsOnboardSideButtonRemaps(pid: 0x00DC))
        XCTAssertFalse(RazerDevices.detectsOnboardSideButtonRemaps(pid: 0x00DB))
        XCTAssertFalse(RazerDevices.detectsOnboardSideButtonRemaps(pid: 0x00BA))
    }
}

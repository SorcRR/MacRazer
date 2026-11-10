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

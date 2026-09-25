// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class BLEVendorProtocolTests: XCTestCase {
    func testReadHeaderUsesVendorKeyAndRequestID() {
        XCTAssertEqual(Array(BLEVendorProtocol.readHeader(request: 0x30, key: BLEVendorProtocol.battery)),
                       [0x30, 0, 0, 0, 0x05, 0x81, 0, 1])
        XCTAssertEqual(Array(BLEVendorProtocol.readHeader(request: 0x31, key: BLEVendorProtocol.buttonBindingGet)),
                       [0x31, 0, 0, 0, 0x08, 0x84, 0, 0x60])
    }

    func testSleepTimeoutReadIsLittleEndianAndRejectsShortPayloads() throws {
        XCTAssertEqual(Array(BLEVendorProtocol.readHeader(request: 0x45, key: BLEVendorProtocol.sleepTimeoutGet)),
                       [0x45, 0, 0, 0, 0x05, 0x84, 0, 0])
        XCTAssertEqual(try BLEVendorProtocol.parseSleepTimeout(Data([0x2C, 0x01])), 300)
        XCTAssertThrowsError(try BLEVendorProtocol.parseSleepTimeout(Data([0x2C])))
    }

    func testWriteFramesSplitDpiPayloadIntoGattSizedChunks() {
        let payload = Data(repeating: 0xA5, count: 38)
        let frames = BLEVendorProtocol.writeFrames(request: 0x31, key: BLEVendorProtocol.dpiStagesSet, payload: payload)
        XCTAssertEqual(Array(frames[0]), [0x31, 38, 0, 0, 0x0B, 0x04, 1, 0])
        XCTAssertEqual(frames.map(\.count), [8, 20, 18])
        XCTAssertEqual(Data(frames.dropFirst().flatMap(Array.init)), payload)
    }

    func testResponsePayloadMatchesRequestAndReassemblesFragments() throws {
        let header = Data([0x31, 3, 0, 0, 0, 0, 0, 2] + Array(repeating: 0, count: 12))
        let payload = try BLEVendorProtocol.payload(from: [header, Data([4, 5]), Data([6])], request: 0x31)
        XCTAssertEqual(Array(payload), [4, 5, 6])
    }

    func testMissingMismatchedAndMalformedResponsesFailClosed() {
        XCTAssertThrowsError(try BLEVendorProtocol.payload(from: [], request: 0x32))
        let wrongRequest = Data([0x31, 1, 0, 0, 0, 0, 0, 2])
        XCTAssertThrowsError(try BLEVendorProtocol.payload(from: [wrongRequest, Data([1])], request: 0x32))
        let shortPayload = Data([0x32, 2, 0, 0, 0, 0, 0, 2])
        XCTAssertThrowsError(try BLEVendorProtocol.payload(from: [shortPayload, Data([1])], request: 0x32))
        let rejected = Data([0x32, 0, 0, 0, 0, 0, 0, 3])
        XCTAssertThrowsError(try BLEVendorProtocol.payload(from: [rejected], request: 0x32))
    }

    func testDpiReadDecodeAndActiveStageMapping() throws {
        // Three entries, deliberately ordered differently from their IDs. Active token 1
        // identifies the third entry, matching the device's observed protocol behavior.
        let bytes: [UInt8] = [1, 3,
            2, 0x80, 0x0C, 0x80, 0x0C, 0, 0,
            0, 0x20, 0x03, 0x20, 0x03, 0, 0,
            1, 0x40, 0x06, 0x40, 0x06, 0, 0]
        let snapshot = try BLEVendorProtocol.parseDpiStages(Data(bytes))
        XCTAssertEqual(snapshot, .init(active: 2, stageIDs: [2, 0, 1, 2, 3], values: [3200, 800, 1600],
                                      slots: [3200, 800, 1600, 1600, 1600], marker: 0))
        let report = BLEVendorProtocol.syntheticStagesReport(snapshot)
        XCTAssertEqual(RazerCommands.parseDPIStages(report), [3200, 800, 1600])
        XCTAssertEqual(RazerCommands.parseActiveDPIStage(report), 2)
    }

    func testDpiWriteKeepsStageIdsAndProducesLittleEndianValues() {
        let payload = BLEVendorProtocol.dpiStagePayload(values: [800, 1600, 3200], active: 1,
                                                        stageIDs: [2, 0, 1])
        XCTAssertEqual(Array(payload.prefix(9)), [0, 3, 2, 0x20, 0x03, 0x20, 0x03, 0, 0])
        XCTAssertEqual(payload.count, 38)
        XCTAssertEqual(payload[36], 0x03, "the fifth-slot marker must be present")
    }

    func testDpiWritePreservesUneditedTailSlotsFromSnapshot() {
        let payload = BLEVendorProtocol.dpiStagePayload(values: [800, 1600, 3200], active: 1,
            stageIDs: [1, 2, 3, 4, 5], preservedSlots: [800, 1600, 3200, 6400, 12000], marker: 0x03)
        XCTAssertEqual(Array(payload[23..<37]), [4, 0, 0x19, 0, 0x19, 0, 0, 5, 0xE0, 0x2E, 0xE0, 0x2E, 0, 3])
    }

    func testDpiWriteReadbackMustMatchRequestedValue() throws {
        let write = RazerCommands.setDPI(x: 1600, y: 1600)
        let matching = BLEVendorProtocol.DpiSnapshot(active: 1, stageIDs: [1, 2], values: [800, 1600],
                                                       slots: [800, 1600, 1600, 1600, 1600], marker: 3)
        XCTAssertNoThrow(try BLEVendorProtocol.verifyDpiReadback(for: write, snapshot: matching))

        let stale = BLEVendorProtocol.DpiSnapshot(active: 0, stageIDs: [1, 2], values: [800, 1600],
                                                    slots: [800, 1600, 1600, 1600, 1600], marker: 3)
        XCTAssertThrowsError(try BLEVendorProtocol.verifyDpiReadback(for: write, snapshot: stale))
    }

    func testDpiStageWriteReadbackMustMatchStagesAndActiveIndex() throws {
        let write = RazerCommands.setDPIStages([800, 1600, 3200], activeStage: 2)
        let matching = BLEVendorProtocol.DpiSnapshot(active: 2, stageIDs: [1, 2, 3], values: [800, 1600, 3200],
                                                       slots: [800, 1600, 3200, 3200, 3200], marker: 3)
        XCTAssertNoThrow(try BLEVendorProtocol.verifyDpiReadback(for: write, snapshot: matching))

        let stale = BLEVendorProtocol.DpiSnapshot(active: 1, stageIDs: [1, 2, 3], values: [800, 1600, 3200],
                                                    slots: [800, 1600, 3200, 3200, 3200], marker: 3)
        XCTAssertThrowsError(try BLEVendorProtocol.verifyDpiReadback(for: write, snapshot: stale))
    }

    func testMalformedDpiStageTableIsRejected() {
        XCTAssertThrowsError(try BLEVendorProtocol.parseDpiStages(Data([0, 0, 0, 0, 0, 0, 0, 0, 0])))
        XCTAssertThrowsError(try BLEVendorProtocol.parseDpiStages(Data([0, 6] + Array(repeating: 0, count: 40))))
        XCTAssertThrowsError(try BLEVendorProtocol.parseDpiStages(Data([0, 2] + Array(repeating: 0, count: 7))))
    }

    func testDpiReadAcceptsMissingFinalReservedMarkerButNotMissingDpiData() throws {
        let truncated = Data([3, 5,
            1, 0x90, 0x01, 0x90, 0x01, 0, 0,
            2, 0x20, 0x03, 0x20, 0x03, 0, 0,
            3, 0x40, 0x06, 0x40, 0x06, 0, 0,
            4, 0x80, 0x0C, 0x80, 0x0C, 0, 0,
            5, 0x00, 0x19, 0x00, 0x19, 0])
        let snapshot = try BLEVendorProtocol.parseDpiStages(truncated)
        XCTAssertEqual(snapshot.values, [400, 800, 1600, 3200, 6400])
        XCTAssertEqual(snapshot.active, 2)
        XCTAssertEqual(snapshot.marker, 0x03, "missing reserved marker uses the safe write default")
        XCTAssertThrowsError(try BLEVendorProtocol.parseDpiStages(Data(truncated.dropLast(2))))
    }

    func testDpiCycleButtonBindingsEncodeAndDecodeSupportedMouseActions() throws {
        for binding in BLEVendorProtocol.DPIButtonBinding.allCases {
            let payload = BLEVendorProtocol.dpiButtonPayload(for: binding)
            XCTAssertEqual(payload.count, 10)
            XCTAssertEqual(payload[0], 0x01)
            XCTAssertEqual(payload[1], 0x60)
            XCTAssertEqual(try BLEVendorProtocol.parseDpiButtonBinding(payload), binding)
        }

        XCTAssertEqual(Array(BLEVendorProtocol.dpiButtonPayload(for: .dpiCycle)),
                       [0x01, 0x60, 0x00, 0x06, 0x01, 0x06, 0, 0, 0, 0])
        XCTAssertEqual(Array(BLEVendorProtocol.dpiButtonPayload(for: .back)),
                       [0x01, 0x60, 0x00, 0x01, 0x01, 0x04, 0, 0, 0, 0])
    }

    func testDpiCycleKeyboardShortcutRoundTripsAndMacKeycodesMapToHID() throws {
        let shortcut = BLEVendorProtocol.DPIButtonBinding.keyboardShortcut(hidUsage: 0x06, modifiers: 0x08)
        let payload = BLEVendorProtocol.dpiButtonPayload(for: shortcut)
        XCTAssertEqual(Array(payload), [0x01, 0x60, 0x00, 0x02, 0x02, 0x08, 0x06, 0, 0, 0])
        XCTAssertEqual(try BLEVendorProtocol.parseDpiButtonBinding(payload), shortcut)
        XCTAssertEqual(BLEVendorProtocol.hidUsage(forMacKeyCode: 8), 0x06, "Mac C maps to USB HID C")
        XCTAssertEqual(BLEVendorProtocol.hidUsage(forMacKeyCode: 123), 0x50, "Mac Left Arrow maps to HID Left Arrow")
        XCTAssertNil(BLEVendorProtocol.hidUsage(forMacKeyCode: 999), "unknown keys must not be guessed")
        XCTAssertEqual(BLEVendorProtocol.shortcutLabel(hidUsage: 0x06, modifiers: 0x08), "⌘C")
        for preset in ButtonRemapper.presets {
            XCTAssertNotNil(BLEVendorProtocol.hidUsage(forMacKeyCode: preset.keyCode), preset.name)
        }
    }

    func testDpiCycleButtonReadDecodesPackedBluetoothResponseAndRejectsUnsupportedActions() throws {
        let packedDefault: [UInt8] = [0x60, 0, 0x06, 0x06, 0x01, 0x01, 0x06, 0x06,
                                      0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(try BLEVendorProtocol.parseDpiButtonBinding(Data(packedDefault)), .dpiCycle)

        let packedBack: [UInt8] = [0x60, 0, 0x01, 0x01, 0x01, 0x01, 0x04, 0x04,
                                   0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(try BLEVendorProtocol.parseDpiButtonBinding(Data(packedBack)), .back)

        let unsupportedFunctionBlock: [UInt8] = [0x03, 0x01, 0x06, 0, 0, 0, 0]
        let unsupported = Data([0x01, 0x60, 0] + unsupportedFunctionBlock)
        XCTAssertThrowsError(try BLEVendorProtocol.parseDpiButtonBinding(unsupported))
        XCTAssertThrowsError(try BLEVendorProtocol.parseDpiButtonBinding(Data([0x60, 0])))
    }
}

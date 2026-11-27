// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// Fixtures are real notifications captured from a Cobra HyperSpeed over Bluetooth
/// (PID 0x00DC), so these pin the protocol as the hardware speaks it, not as we guessed.
final class BLEProtocolTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    /// Feed frames through an assembler for request `id`, as `BluetoothDevice` does.
    private func assemble(_ id: UInt8, _ frames: [String]) throws -> Data {
        var a = BLEProtocol.Assembler(id: id)
        for f in frames { a.add(data(f)) }
        return try a.result()
    }

    // MARK: Framing

    func testReadRequestIsOneHeaderFrame() {
        let req = BLEProtocol.request(for: RazerCommands.getBatteryLevel(), stages: nil)!
        XCTAssertEqual(BLEProtocol.frames(id: 0x30, request: req), [data("30 00 00 00 05 81 00 01")])
    }

    func testWritePayloadIsSplitIntoTwentyByteFrames() {
        let table = BLEProtocol.DPIStageTable(active: 3, values: [400, 800, 1600, 3200, 6400])
        let req = BLEProtocol.Request(key: .dpiStagesSet, payload: table.encoded(), reply: .ack)
        let frames = BLEProtocol.frames(id: 0x40, request: req)
        XCTAssertEqual(frames.first, data("40 25 00 00 0b 04 01 00"), "header carries the 37-byte length")
        XCTAssertEqual(frames.dropFirst().map(\.count), [20, 17])
        XCTAssertEqual(Data(frames.dropFirst().joined()), Data(table.encoded()))
    }

    // MARK: Assembling replies

    func testAssemblerIgnoresTheUnsolicitedFrameAndOtherIDs() throws {
        let payload = try assemble(0x30, [
            "01 00 00 00 00 00 00 03",   // sent by the mouse when notifications are enabled
            "2f 01 00 00 00 00 00 02",   // a late reply to an earlier request
            "30 01 00 00 00 00 00 02",
            "61",
        ])
        XCTAssertEqual(payload, data("61"))
    }

    func testAssemblerJoinsContinuationFrames() throws {
        let payload = try assemble(0x32, [
            "32 24 00 00 00 00 00 02",
            "04 05 01 90 01 90 01 00 00 02 20 03 20 03 00 00 03 40 06 40",
            "06 00 00 04 80 0c 80 0c 00 00 05 00 19 00 19 00",
        ])
        XCTAssertEqual(payload.count, 0x24)
    }

    func testAssemblerMapsStatusBytes() {
        XCTAssertThrowsError(try assemble(0x33, ["33 00 00 00 00 00 00 03"])) {
            guard case HIDDevice.HIDError.commandFailed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try assemble(0x36, ["36 00 00 00 00 00 00 05"])) {
            guard case HIDDevice.HIDError.notSupported = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try assemble(0x30, ["30 02 00 00 00 00 00 02", "2c"]), "short payload") {
            guard case HIDDevice.HIDError.timeout = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: Replies folded into USB reports

    func testBatteryIsZeroTo255LikeUSB() throws {
        // 0x61 = 97 raw, while the standard Battery Service said 39%. A "≤ 100 means percent"
        // reading would have shown 97%.
        let report = RazerCommands.getBatteryLevel()
        let resp = try BLEProtocol.response(to: report, reply: .battery, payload: data("61"))
        XCTAssertEqual(RazerCommands.batteryPercent(fromRaw: resp.arguments[1]), 38)
    }

    func testSerialMatchesTheUSBParser() throws {
        let payload = try assemble(0x38, [
            "38 16 00 00 00 00 00 02",
            "50 4d 32 35 33 33 48 33 37 34 30 31 32 35 37 00 00 00 00 00",
            "00 00",
        ])
        let resp = try BLEProtocol.response(to: RazerCommands.getSerial(), reply: .serial, payload: payload)
        // The same serial the dongle reports, so Bluetooth shares the mouse's battery history.
        XCTAssertEqual(RazerCommands.parseSerial(resp), "PM2533H37401257")
    }

    func testStageTableDecodesTheTruncatedLastRecord() throws {
        let payload = try assemble(0x32, [
            "32 24 00 00 00 00 00 02",
            "04 05 01 90 01 90 01 00 00 02 20 03 20 03 00 00 03 40 06 40",
            "06 00 00 04 80 0c 80 0c 00 00 05 00 19 00 19 00",
        ])
        let table = try BLEProtocol.DPIStageTable(decoding: Array(payload))
        XCTAssertEqual(table, BLEProtocol.DPIStageTable(active: 3, values: [400, 800, 1600, 3200, 6400]))

        let stages = try BLEProtocol.response(to: RazerCommands.getDPIStages(), reply: .dpiStages, payload: payload)
        XCTAssertEqual(RazerCommands.parseDPIStages(stages), [400, 800, 1600, 3200, 6400])
        let dpi = try BLEProtocol.response(to: RazerCommands.getDPI(), reply: .dpi, payload: payload)
        XCTAssertEqual(RazerCommands.parseDPI(dpi).x, 3200)
    }

    func testStageTableRoundTrips() throws {
        let table = BLEProtocol.DPIStageTable(active: 1, values: [800, 1600, 3200])
        XCTAssertEqual(try BLEProtocol.DPIStageTable(decoding: table.encoded()), table)
    }

    func testDpiButtonBindingsRoundTrip() throws {
        for binding in BLEProtocol.DPIButtonBinding.allCases + [.softwareBridge] {
            let payload = BLEProtocol.dpiButtonPayload(for: binding)
            XCTAssertEqual(try BLEProtocol.parseDpiButtonBinding(payload), binding)
        }
    }

    func testDpiButtonPayloadUsesF20ForSoftwareBridge() throws {
        XCTAssertEqual(BLEProtocol.dpiButtonPayload(for: .softwareBridge),
                       Data([0x01, 0x60, 0x00, 0x02, 0x02, 0x00, 0x6F, 0, 0, 0]))
        XCTAssertEqual(try BLEProtocol.parseDpiButtonBinding(
            Data([0x01, 0x60, 0x00, 0x02, 0x02, 0x00, 0x6F, 0, 0, 0])),
                       .softwareBridge)
    }

    func testSleepTimeoutUsesLittleEndianSeconds() throws {
        XCTAssertEqual(BLEProtocol.Key.powerTimeoutGet.bytes, [0x05, 0x84, 0x00, 0x00])
        XCTAssertEqual(BLEProtocol.Key.powerTimeoutSet.bytes, [0x05, 0x04, 0x00, 0x00])
        XCTAssertEqual(BLEProtocol.sleepTimeoutPayload(seconds: 300), Data([0x2C, 0x01]))
        XCTAssertEqual(try BLEProtocol.parseSleepTimeout(Data([0x2C, 0x01])), 300)
        XCTAssertNil(BLEProtocol.sleepTimeoutPayload(seconds: 59))
        XCTAssertNil(BLEProtocol.sleepTimeoutPayload(seconds: 61))
        XCTAssertNil(BLEProtocol.sleepTimeoutPayload(seconds: 901))
        XCTAssertThrowsError(try BLEProtocol.parseSleepTimeout(Data([0x2D, 0x01])))
    }

    func testDpiStageEditPreservesActiveStageAndOtherValues() throws {
        let original = BLEProtocol.DPIStageTable(active: 2, values: [400, 800, 1600, 3200, 6400])
        var edited = original.values
        edited[1] = 1200
        let table = BLEProtocol.DPIStageTable(active: original.active, values: edited)
        XCTAssertEqual(table.active, 2)
        XCTAssertEqual(try BLEProtocol.DPIStageTable(decoding: table.encoded()), table)
        XCTAssertEqual(table.values, [400, 1200, 1600, 3200, 6400])
    }

    func testStageTableRejectsAnActiveIDItDoesNotList() {
        XCTAssertThrowsError(try BLEProtocol.DPIStageTable(decoding: [0x09, 0x01, 0x01, 0x90, 0x01, 0x90, 0x01]))
    }

    func testBrightnessUsesTheRequestedLED() throws {
        let get = BLEProtocol.request(for: RazerCommands.getBrightness(led: Razer.logoLed), stages: nil)!
        XCTAssertEqual(get.key, BLEProtocol.Key(0x10, 0x85, 0x01, 0x04))
        let set = BLEProtocol.request(for: RazerCommands.setBrightness(0x80, led: Razer.logoLed), stages: nil)!
        XCTAssertEqual(set.key, BLEProtocol.Key(0x10, 0x05, 0x01, 0x04))
        XCTAssertEqual(set.payload, [0x80])
        let resp = try BLEProtocol.response(to: RazerCommands.getBrightness(led: Razer.logoLed),
                                            reply: .brightness, payload: data("08"))
        XCTAssertEqual(resp.arguments[2], 0x08)
    }

    // MARK: USB requests with and without a BLE equivalent

    func testSetDPISelectsAnExistingStage() {
        let stages = BLEProtocol.DPIStageTable(active: 3, values: [400, 800, 1600, 3200, 6400])
        let req = BLEProtocol.request(for: RazerCommands.setDPI(x: 800, y: 800), stages: stages)
        XCTAssertEqual(req?.key, .dpiStagesSet)
        XCTAssertEqual(req.map { try? BLEProtocol.DPIStageTable(decoding: $0.payload) },
                       BLEProtocol.DPIStageTable(active: 1, values: [400, 800, 1600, 3200, 6400]))
    }

    func testSetDPIToAValueOutsideTheStagesIsNotSupported() {
        let stages = BLEProtocol.DPIStageTable(active: 0, values: [400, 800])
        XCTAssertNil(BLEProtocol.request(for: RazerCommands.setDPI(x: 1234, y: 1234), stages: stages),
                     "rewriting a stage behind the user's back is not a DPI change")
        XCTAssertNil(BLEProtocol.request(for: RazerCommands.setDPI(x: 800, y: 800), stages: nil))
    }

    func testSetStagesTranslatesFromTheUSBLayout() throws {
        let req = BLEProtocol.request(for: RazerCommands.setDPIStages([800, 1600, 3200], activeStage: 2), stages: nil)
        XCTAssertEqual(try req.map { try BLEProtocol.DPIStageTable(decoding: $0.payload) },
                       BLEProtocol.DPIStageTable(active: 2, values: [800, 1600, 3200]))
    }

    func testStaticColourOnlyAmongEffects() {
        let req = BLEProtocol.request(for: RazerCommands.setStatic(rgb: RGB(r: 1, g: 2, b: 3)), stages: nil)
        XCTAssertEqual(req?.key, .staticColor)
        XCTAssertEqual(req?.payload, [0x04, 0, 0, 0, 0, 1, 2, 3])
        XCTAssertNil(BLEProtocol.request(for: RazerCommands.setBreathingSingle(rgb: RGB(r: 1, g: 2, b: 3)), stages: nil),
                     "no known BLE encoding for breathing; never sent as a guess")
        XCTAssertNil(BLEProtocol.request(for: RazerCommands.setBreathingDual(rgb1: RGB(r: 1, g: 2, b: 3),
                                                                              rgb2: RGB(r: 4, g: 5, b: 6)), stages: nil))
        XCTAssertNil(BLEProtocol.request(for: RazerCommands.setBreathingRandom(), stages: nil))
        XCTAssertNil(BLEProtocol.request(for: RazerCommands.setSpectrum(), stages: nil))
        XCTAssertNil(BLEProtocol.request(for: RazerCommands.setWave(), stages: nil))
        XCTAssertNil(BLEProtocol.request(for: RazerCommands.setNone(), stages: nil))
    }

    func testCommandsWithoutABLEEquivalent() {
        XCTAssertNil(BLEProtocol.request(for: RazerCommands.getPollingRate(), stages: nil))
        XCTAssertNil(BLEProtocol.request(for: RazerCommands.setPollingRate(500), stages: nil))
        XCTAssertNil(BLEProtocol.request(for: RazerCommands.getChargingStatus(), stages: nil),
                     "unknown over BLE: the poll treats it as 'charging unknown'")
    }

    func testAssemblerSaysWhichFramesItTook() {
        var a = BLEProtocol.Assembler(id: 0x30)
        XCTAssertFalse(a.add(data("01 00 00 00 00 00 00 03")), "the mouse's own frame")
        XCTAssertTrue(a.add(data("30 01 00 00 00 00 00 02")))
        XCTAssertTrue(a.add(data("61")))
        XCTAssertFalse(a.add(data("05 05 02 03 84 03 84")), "after the reply is complete")
    }

    // MARK: Gesture trace

    func testTraceProbesAreTheListedReadsInOrder() {
        XCTAssertEqual(BLEProtocol.traceProbeKeys.map(\.bytes), [
            [0x01, 0x82, 0x00, 0x00], [0x01, 0x80, 0x00, 0x00],
            [0x08, 0x80, 0x00, 0x00], [0x08, 0x80, 0x01, 0x00], [0x08, 0x83, 0x01, 0x00],
            [0x08, 0x84, 0x00, 0x60], [0x08, 0x84, 0x01, 0x60], [0x08, 0x84, 0x02, 0x60],
            [0x08, 0x84, 0x03, 0x60], [0x08, 0x84, 0x04, 0x60], [0x08, 0x84, 0x05, 0x60],
            [0x08, 0x84, 0x00, 0x80], [0x08, 0x84, 0x01, 0x80],
            [0x03, 0x82, 0x00, 0x00], [0x0B, 0x81, 0x00, 0x00],
        ])
        for key in BLEProtocol.traceProbeKeys {
            let request = BLEProtocol.traceReadRequest(key)
            XCTAssertEqual(request?.payload, [], "\(key.bytes)")
            XCTAssertEqual(request.map { BLEProtocol.frames(id: 0x30, request: $0).count }, 1, "a header and nothing else")
        }
    }

    func testTraceReadRefusesAnyKeyWithoutTheReadBit() {
        for key in [BLEProtocol.Key.deviceModeSet, .dpiButtonSet, .dpiStagesSet, .staticColor, .powerTimeoutSet,
                    BLEProtocol.Key(0x01, 0x04, 0x00, 0x00)] {
            XCTAssertNil(BLEProtocol.traceReadRequest(key), "\(key.bytes)")
        }
    }

    func testDeviceModeRequestWritesOnlyNormalOrDriverMode() {
        XCTAssertEqual(BLEProtocol.frames(id: 0x41, request: BLEProtocol.deviceModeRequest(.driver)),
                       [data("41 02 00 00 01 02 00 00"), data("03 00")])
        XCTAssertEqual(BLEProtocol.frames(id: 0x42, request: BLEProtocol.deviceModeRequest(.normal)),
                       [data("42 02 00 00 01 02 00 00"), data("00 00")])
        XCTAssertEqual((0...255).compactMap { BLEProtocol.DeviceMode(rawValue: UInt8($0)) }, [.normal, .driver])
        XCTAssertEqual(BLEProtocol.Key.deviceModeGet.bytes, [0x01, 0x82, 0x00, 0x00])
    }

    /// The mode is read with `01 82 00 00` and no payload, and answers a little-endian u16:
    /// `03 00` driver, `00 00` normal. Anything shorter is no answer.
    func testDeviceModeIsReadAsALittleEndianU16() {
        XCTAssertEqual(BLEProtocol.frames(id: 0x43, request: BLEProtocol.deviceModeReadRequest),
                       [data("43 00 00 00 01 82 00 00")])
        XCTAssertEqual(BLEProtocol.parseDeviceMode([0x03, 0x00]), 3)
        XCTAssertEqual(BLEProtocol.parseDeviceMode([0x00, 0x00]), 0)
        XCTAssertEqual(BLEProtocol.parseDeviceMode([0x03, 0x00, 0xFF]), 3, "past the value")
        XCTAssertEqual(BLEProtocol.parseDeviceMode([0x00, 0x01]), 0x0100)
        XCTAssertNil(BLEProtocol.parseDeviceMode([0x03]))
        XCTAssertNil(BLEProtocol.parseDeviceMode([UInt8]()))
        XCTAssertEqual(BLEProtocol.DeviceMode.driver.value, 3)
        XCTAssertEqual(BLEProtocol.DeviceMode.normal.value, 0)
    }

    /// A short press in driver mode steps to the next stage, back to the first after the
    /// last, as the button does in normal mode, and leaves the stages as they are. With one
    /// stage there is nothing to step to.
    func testTheNextStageWrapsAndKeepsTheStages() throws {
        let stages = [400, 800, 1600, 3200, 6400]
        XCTAssertEqual(BLEProtocol.DPIStageTable(active: 0, values: stages).nextStage(),
                       BLEProtocol.DPIStageTable(active: 1, values: stages))
        XCTAssertEqual(BLEProtocol.DPIStageTable(active: 3, values: stages).nextStage()?.active, 4)
        XCTAssertEqual(BLEProtocol.DPIStageTable(active: 4, values: stages).nextStage()?.active, 0, "after the last, the first")
        XCTAssertEqual(BLEProtocol.DPIStageTable(active: 0, values: [800, 800]).nextStage()?.active, 1,
                       "by position, so two stages at the same DPI don't stop it")
        XCTAssertNil(BLEProtocol.DPIStageTable(active: 0, values: [1600]).nextStage())
        let next = try XCTUnwrap(BLEProtocol.DPIStageTable(active: 2, values: stages).nextStage())
        XCTAssertEqual(next.encoded().first, 4, "the active stage's id, from 1")
        XCTAssertEqual(try BLEProtocol.DPIStageTable(decoding: next.encoded()), next)
    }

    func testTraceAssemblerKeepsTheWholeReply() {
        var a = BLEProtocol.TraceAssembler(id: 0x30)
        XCTAssertFalse(a.add(data("01 00 00 00 00 00 00 03")))
        XCTAssertTrue(a.add(data("30 02 00 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00")))
        XCTAssertFalse(a.isComplete)
        XCTAssertTrue(a.add(data("03 00 ff")))
        XCTAssertTrue(a.isSuccess)
        XCTAssertEqual(a.payload, [0x03, 0x00, 0xFF], "past the declared length too")
        XCTAssertEqual(a.header?.count, 20)
        XCTAssertFalse(a.add(data("30 00 00 00 00 00 00 02")), "nothing after a success")
    }

    func testTraceAssemblerReadsA24BitLength() {
        var a = BLEProtocol.TraceAssembler(id: 0x31)
        a.add(data("31 2c 01 00 00 00 00 02"))
        XCTAssertEqual(a.declaredLength, 300, "an Assembler would take 0x2c")
        for _ in 0..<14 { a.add(Data(repeating: 0xAB, count: 20)) }
        XCTAssertFalse(a.isComplete)
        a.add(Data(repeating: 0xAB, count: 20))
        XCTAssertTrue(a.isSuccess)
        XCTAssertEqual(a.payload.count, 300)
    }

    func testTraceAssemblerLetsALaterSuccessReplaceARefusal() {
        var a = BLEProtocol.TraceAssembler(id: 0x32)
        a.add(data("32 00 00 00 00 00 00 03"))
        XCTAssertTrue(a.isComplete)
        XCTAssertFalse(a.isSuccess)
        XCTAssertTrue(a.add(data("32 02 00 00 00 00 00 02")))
        a.add(data("00 00"))
        XCTAssertTrue(a.isSuccess)
        XCTAssertEqual(a.replacedStatuses, [0x03])
        XCTAssertEqual(a.payload, [0x00, 0x00])
    }
}

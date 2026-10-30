// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The device test's Bluetooth reads and the report built from them.
final class BluetoothReportTests: XCTestCase {
    /// Answers keys from `answers`, refuses the rest, and stops answering from `silentAfter`
    /// reads on.
    private final class Mouse: BluetoothReadChannel {
        var answers: [[UInt8]: [UInt8]] = [:]
        var silentAfter = Int.max
        private(set) var asked: [[UInt8]] = []
        func read(_ key: BLEProtocol.Key) throws -> Data {
            asked.append(key.bytes)
            if asked.count > silentAfter { throw HIDDevice.HIDError.timeout }
            guard let payload = answers[key.bytes] else { throw HIDDevice.HIDError.notSupported }
            return Data(payload)
        }
    }

    /// The rule that lets this run on anyone's mouse: every key is a read.
    func testEveryBluetoothReadIsAGet() {
        for (name, key) in DeviceTestSteps.bluetoothReads {
            XCTAssertNotEqual(key.bytes[1] & 0x80, 0, "\(name) is not a get")
        }
    }

    func testTheReadsAndTheButtonTable() {
        let mouse = Mouse()
        mouse.answers = [
            BLEProtocol.Key.battery.bytes: [0xC8],
            DeviceTestSteps.bluetoothButtonRead(0x60).bytes: [0x06, 0x01, 0x06],
            DeviceTestSteps.bluetoothButtonRead(0x02).bytes: [0x01, 0x01, 0x02],
            DeviceTestSteps.bluetoothButtonRead(0x30).bytes: [0, 0, 0],
            [0x10, 0x85, 0x01, 0x04]: [0x80],
            [0x10, 0x83, 0x01, 0x04]: [0x01],
        ]
        let data = DeviceTestSteps.bluetoothCapabilities(mouse)
        func answer(_ name: String) -> DeviceReport.CapabilityAnswer? { data.reads.first { $0.name == name }?.answer }
        XCTAssertEqual(data.reads.count, DeviceTestSteps.bluetoothReads.count)
        XCTAssertEqual(answer("battery"), .answered)
        XCTAssertEqual(answer("sleepTimeout"), .notSupported)
        XCTAssertEqual(data.reads.first { $0.name == "brightness" && $0.led == 0x04 }?.response, [0x80])
        XCTAssertEqual(data.buttonTable?.map(\.id), [0x02, 0x60], "0x30 is all zeros")
        XCTAssertEqual(data.buttonTable?.first?.block, [0x01, 0x01, 0x02], "kept as the mouse sent it")
    }

    func testNoButtonTableWithoutAProbeAnswer() {
        XCTAssertNil(DeviceTestSteps.bluetoothCapabilities(Mouse()).buttonTable)
    }

    /// Each silent read costs a second and a half, so three in a row end the asking.
    func testAMouseThatStopsAnsweringIsLeftAlone() {
        let mouse = Mouse()
        mouse.silentAfter = 2
        let data = DeviceTestSteps.bluetoothCapabilities(mouse)
        XCTAssertEqual(mouse.asked.count, 5)
        XCTAssertTrue(data.reads.dropFirst(2).allSatisfy { $0.answer == .noAnswer })
    }

    private let hid = HIDDevice.BluetoothHID(vendorID: 0x068E, productID: 0x00C9, interfaces: [
        .init(productID: 0x00C9, product: "PCV2 Ver", usagePage: 1, usage: 2, maxFeatureReportSize: 1,
              maxInputReportSize: 8, transport: "Bluetooth Low Energy"),
    ])

    /// #35's Pro Click V2: no Razer service, so Identify isn't on this mouse, yet the battery
    /// service and the interface sizes still make a useful report.
    func testAMouseWithoutRazersService() {
        let probe = DeviceReport.BluetoothData(services: ["180F", "1812"], batteryLevel: 64)
        let report = DeviceTestSteps.bluetoothReport(name: "PCV2 Ver", hid: hid, probe: probe, capabilities: nil)
        XCTAssertEqual(report.device.connection, .bluetooth)
        XCTAssertEqual(report.device.vendorID, 0x068E)
        XCTAssertEqual(report.device.interfaces.first?.maxFeatureReportSize, 1)
        XCTAssertEqual(report.identify.outcome, .notSupported)
        XCTAssertEqual(report.battery.outcome, .passed)
        XCTAssertEqual(report.battery.data?.percent, 64)
        XCTAssertEqual(report.verdict?.kind, .partlyTested)
        XCTAssertEqual(report.bluetooth, probe)
    }

    /// Razer's own battery read wins, on the USB scale. Ids fall back to the PnP ID, so a
    /// report never goes out with a vendor the Worker refuses.
    func testBatteryAndIdsFallBack() {
        let probe = DeviceReport.BluetoothData(razerService: true, pnpVendorID: 0x068E, pnpProductID: 0x00E4, batteryLevel: 39)
        let reads = DeviceReport.CapabilitiesData(reads: [
            .init(name: "battery", commandClass: 0x05, commandId: 0x81, answer: .answered, response: [0x61]),
        ])
        let none = HIDDevice.BluetoothHID(vendorID: nil, productID: nil, interfaces: [])
        let report = DeviceTestSteps.bluetoothReport(name: "x", hid: none, probe: probe, capabilities: reads)
        XCTAssertEqual(report.battery.data?.raw, 0x61)
        XCTAssertEqual(report.battery.data?.percent, RazerCommands.batteryPercent(fromRaw: 0x61))
        XCTAssertEqual(report.device.vendorID, 0x068E)
        XCTAssertEqual(report.device.productID, 0x00E4)
        XCTAssertEqual(DeviceTestSteps.bluetoothReport(name: "x", hid: none, probe: .init(), capabilities: nil)
            .device.vendorID, BLEProtocol.vendorId)
    }

    func testIdentifyPassesWhenRazersServiceAnswers() {
        let probe = DeviceReport.BluetoothData(services: [BLEProtocol.serviceUUID], razerService: true)
        let answered = DeviceReport.CapabilitiesData(reads: [
            .init(name: "battery", commandClass: 0x05, commandId: 0x81, answer: .answered, response: [0xC8]),
        ])
        XCTAssertEqual(DeviceTestSteps.bluetoothReport(name: "x", hid: hid, probe: probe, capabilities: answered)
            .identify.outcome, .passed)
        XCTAssertEqual(DeviceTestSteps.bluetoothReport(name: "x", hid: hid, probe: probe, capabilities: .init(reads: []))
            .identify.outcome, .failed, "the service is there, but nothing answered")
    }

    func testTheSummarySaysBluetoothAndListsEachZoneOnce() {
        var report = DeviceTestSteps.bluetoothReport(
            name: "Basilisk V4 Pro", hid: hid, probe: .init(razerService: true),
            capabilities: .init(reads: [
                .init(name: "brightness", commandClass: 0x10, commandId: 0x85, led: 0x04, answer: .answered),
                .init(name: "zoneEffect", commandClass: 0x10, commandId: 0x83, led: 0x04, answer: .answered),
            ]))
        report.verdict = report.currentVerdict()
        let summary = DeviceReportOutput.summary(report)
        XCTAssertTrue(summary.contains(", over Bluetooth"))
        XCTAssertTrue(summary.contains("Also answers: lighting zones 0x04\n") || summary.hasSuffix("Also answers: lighting zones 0x04"))
    }
}

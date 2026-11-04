// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The device test's picker: which devices it lists, that a pick wins over the ranking, and
/// what the review asks about a dock.
final class DevicePickerTests: XCTestCase {
    /// The Basilisk Ultimate report's setup: its Mouse Dock (0x007E) and its dongle (0x0088),
    /// neither in the registry, plus an Ornata V2 keyboard.
    private let dock: [HIDInterfaceInfo] = [
        .init(pid: 0x007E, locationID: 0x1100000, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90, productName: "Razer Mouse Dock"),
        .init(pid: 0x007E, locationID: 0x1100000, usagePage: 0x01, usage: 0x06, maxFeatureReportSize: 0, productName: "Razer Mouse Dock"),
    ]
    private let dongle: [HIDInterfaceInfo] = [
        .init(pid: 0x0088, locationID: 0x1200000, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90, productName: "Razer Basilisk Ultimate Dongle"),
    ]
    private let keyboard: [HIDInterfaceInfo] = [
        .init(pid: 0x025D, locationID: 0x1000000, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90, productName: "Razer Ornata V2"),
    ]

    func testCandidatesLeaveOutTheKeyboardAndKeepSelectionsOrder() {
        let interfaces = keyboard + dongle + dock
        let candidates = HIDDeviceSelection.candidates(interfaces: interfaces)
        XCTAssertEqual(candidates.map(\.key.pid), [0x007E, 0x0088], "lower USB location first; no keyboard")
        XCTAssertEqual(candidates.map(\.name), ["Razer Mouse Dock", "Razer Basilisk Ultimate Dongle"])
        XCTAssertEqual(HIDDeviceSelection.controlInterfaceIndex(interfaces: interfaces), candidates.first?.index)
    }

    func testAKnownMouseStillRanksFirst() {
        let known: [HIDInterfaceInfo] = [
            .init(pid: 0x00DB, locationID: 0x3000000, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90, productName: "Razer Cobra HyperSpeed"),
        ]
        XCTAssertEqual(HIDDeviceSelection.candidates(interfaces: dock + known).map(\.key.pid), [0x00DB, 0x007E])
    }

    func testAPickWinsOverTheRanking() {
        let interfaces = dock + dongle
        let picked = HIDDeviceSelection.DeviceKey(pid: 0x0088, locationID: 0x1200000)
        let index = HIDDeviceSelection.controlInterfaceIndex(interfaces: interfaces, preferred: picked)
        XCTAssertEqual(interfaces[index!].pid, 0x0088)
    }

    func testAPickThatIsGoneFallsBackToTheRanking() {
        let unplugged = HIDDeviceSelection.DeviceKey(pid: 0x0088, locationID: 0x1200000)
        let index = HIDDeviceSelection.controlInterfaceIndex(interfaces: dock, preferred: unplugged)
        XCTAssertEqual(dock[index!].pid, 0x007E)
        let keyboardPick = HIDDeviceSelection.DeviceKey(pid: 0x025D, locationID: 0x1000000)
        let withKeyboard = keyboard + dock
        XCTAssertEqual(withKeyboard[HIDDeviceSelection.controlInterfaceIndex(interfaces: withKeyboard, preferred: keyboardPick)!].pid,
                       0x007E, "a pick can't make a keyboard the mouse")
    }

    func testLabelsNumberDevicesThatShareAName() {
        let candidates = HIDDeviceSelection.candidates(interfaces: dock + dongle + [
            .init(pid: 0x0088, locationID: 0x1300000, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90, productName: "Razer Basilisk Ultimate Dongle"),
        ])
        XCTAssertEqual(DeviceTestModel.deviceLabels(candidates), [
            "Razer Mouse Dock", "Razer Basilisk Ultimate Dongle (1)", "Razer Basilisk Ultimate Dongle (2)",
        ])
    }

    func testDocksAreRecognised() {
        XCTAssertTrue(DeviceTestModel.isDock(name: "Razer Mouse Dock Pro"))
        XCTAssertTrue(DeviceTestModel.isDock(name: "Razer HyperFlux V2"))
        XCTAssertTrue(DeviceTestModel.isDock(name: "Razer Mouse Dock"))
        XCTAssertFalse(DeviceTestModel.isDock(name: "Razer Cobra HyperSpeed"))
    }

    func testTheDocksMouseLeadsTheComment() {
        XCTAssertEqual(DeviceTestModel.commentWithDockMouse("Works well", dockMouse: " DeathAdder V3 Pro "),
                       "Mouse on the dock: DeathAdder V3 Pro\n\nWorks well")
        XCTAssertEqual(DeviceTestModel.commentWithDockMouse("", dockMouse: "Viper V2 Pro"), "Mouse on the dock: Viper V2 Pro")
        XCTAssertEqual(DeviceTestModel.commentWithDockMouse("Works well", dockMouse: "  "), "Works well")
        XCTAssertEqual(DeviceTestModel.commentWithDockMouse("Works well", dockMouse: nil), "Works well")
    }

    func testTheDockLineComesOutOfTheCommentCap() {
        XCTAssertEqual(DeviceTestModel.commentLimit(dockMouse: ""), DeviceReportOutput.maxComment)
        let limit = DeviceTestModel.commentLimit(dockMouse: "Viper V2 Pro")
        let full = String(repeating: "a", count: limit)
        XCTAssertEqual(DeviceTestModel.commentWithDockMouse(full, dockMouse: "Viper V2 Pro").count,
                       DeviceReportOutput.maxComment, "a full comment and the dock line fit exactly")
    }

    func testAPickSwitchesOnlyOnTheIntroWithNothingRunning() {
        let dock = HIDDeviceSelection.DeviceKey(pid: 0x007E, locationID: 1)
        let dongle = HIDDeviceSelection.DeviceKey(pid: 0x0088, locationID: 2)
        XCTAssertTrue(DeviceTestModel.canSwitch(to: dongle, stage: .intro, running: false, switching: false, chosen: dock))
        XCTAssertTrue(DeviceTestModel.canSwitch(to: dongle, stage: .intro, running: false, switching: false, chosen: nil))
        XCTAssertFalse(DeviceTestModel.canSwitch(to: dock, stage: .intro, running: false, switching: false, chosen: dock), "already open")
        XCTAssertFalse(DeviceTestModel.canSwitch(to: dongle, stage: .battery, running: false, switching: false, chosen: dock), "mid-run")
        XCTAssertFalse(DeviceTestModel.canSwitch(to: dongle, stage: .intro, running: true, switching: false, chosen: dock))
        XCTAssertFalse(DeviceTestModel.canSwitch(to: dongle, stage: .intro, running: false, switching: true, chosen: dock))
    }

    /// What decides whether a pick took: the open device is that USB device.
    func testAPickTookOnlyWhenThatUSBDeviceIsOpen() {
        final class Fake: RazerTransport {
            let productID: Int, locationID: Int, isBluetooth: Bool
            let productName = "Fake"
            init(_ pid: Int, _ location: Int, bluetooth: Bool = false) { productID = pid; locationID = location; isBluetooth = bluetooth }
            func sendWithRetry(_ report: RazerReport) throws -> RazerReport { report }
            func close() {}
        }
        let key = HIDDeviceSelection.DeviceKey(pid: 0x0088, locationID: 2)
        XCTAssertTrue(MouseController.isOpen(key, Fake(0x0088, 2)))
        XCTAssertFalse(MouseController.isOpen(key, Fake(0x0088, 3)), "same model, other port")
        XCTAssertFalse(MouseController.isOpen(key, Fake(0x007E, 1)), "selection's own pick")
        XCTAssertFalse(MouseController.isOpen(key, Fake(0x0088, 2, bluetooth: true)))
        XCTAssertFalse(MouseController.isOpen(key, nil), "nothing opened")
    }
}

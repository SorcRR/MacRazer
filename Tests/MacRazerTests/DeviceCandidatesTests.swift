// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// Which devices count as a possible mouse, the intro's hint when there's more than one, and
/// what the review asks about a dock.
final class DeviceCandidatesTests: XCTestCase {
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

    func testLabelsNumberDevicesThatShareAName() {
        let candidates = HIDDeviceSelection.candidates(interfaces: dock + dongle + [
            .init(pid: 0x0088, locationID: 0x1300000, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90, productName: "Razer Basilisk Ultimate Dongle"),
        ])
        XCTAssertEqual(DeviceTestModel.deviceLabels(candidates), [
            "Razer Mouse Dock", "Razer Basilisk Ultimate Dongle 1", "Razer Basilisk Ultimate Dongle 2",
        ], "not in the registry, so numbered")
    }

    func testDocksAreRecognised() {
        XCTAssertTrue(DeviceTestModel.isDock(name: "Razer Mouse Dock Pro"))
        XCTAssertTrue(DeviceTestModel.isDock(name: "Razer HyperFlux V2"))
        XCTAssertTrue(DeviceTestModel.isDock(name: "Razer Mouse Dock"))
        XCTAssertFalse(DeviceTestModel.isDock(name: "Razer Cobra HyperSpeed"))
    }

    func testTheDocksMouseLeadsTheComment() {
        XCTAssertEqual(DeviceTestModel.reportComment("Works well", dockMouse: " DeathAdder V3 Pro "),
                       "Mouse on the dock: DeathAdder V3 Pro\n\nWorks well")
        XCTAssertEqual(DeviceTestModel.reportComment("", dockMouse: "Viper V2 Pro"), "Mouse on the dock: Viper V2 Pro")
        XCTAssertEqual(DeviceTestModel.reportComment("Works well", dockMouse: "  "), "Works well")
        XCTAssertEqual(DeviceTestModel.reportComment("Works well", dockMouse: nil), "Works well")
        XCTAssertNil(DeviceTestModel.reportComment(" ", dockMouse: nil))
    }

    func testTheDockLineComesOutOfTheCommentCap() {
        XCTAssertEqual(DeviceTestModel.commentLimit(dockMouse: nil), DeviceReportOutput.maxComment)
        XCTAssertEqual(DeviceTestModel.commentLimit(dockMouse: " "), DeviceReportOutput.maxComment)
        let limit = DeviceTestModel.commentLimit(dockMouse: "Viper V2 Pro")
        let full = String(repeating: "a", count: limit)
        XCTAssertEqual(DeviceTestModel.reportComment(full, dockMouse: "Viper V2 Pro")?.count,
                       DeviceReportOutput.maxComment, "a full comment and the dock line fit exactly")
        let tooLong = DeviceTestModel.reportComment(full + "zzz", dockMouse: "Viper V2 Pro")!
        XCTAssertTrue(tooLong.hasPrefix("Mouse on the dock: Viper V2 Pro"))
        XCTAssertFalse(tooLong.contains("z"), "the comment's end is what's cut")
    }

    /// Emoji count as one character each but several UTF-16 units, which is what the Worker caps.
    func testTheDockLineFitsTheUnitCapToo() {
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: DeviceReportOutput.maxCommentUnits / 11)
        let comment = DeviceTestModel.reportComment(emoji, dockMouse: "Viper V2 Pro")!
        XCTAssertTrue(comment.hasPrefix("Mouse on the dock: Viper V2 Pro"))
        XCTAssertLessThanOrEqual(comment.utf16.count, DeviceReportOutput.maxCommentUnits)
    }

    func testTheCableWinsOverItsOwnDongle() {
        let dongle: [HIDInterfaceInfo] = [
            .init(pid: 0x00DB, locationID: 0x1000000, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90, productName: "Razer Cobra HyperSpeed"),
        ]
        let cable: [HIDInterfaceInfo] = [
            .init(pid: 0x00DA, locationID: 0x2000000, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90, productName: "Razer Cobra HyperSpeed"),
        ]
        // The dongle sits on the lower port, which used to win.
        XCTAssertEqual(HIDDeviceSelection.candidates(interfaces: dongle + cable).map(\.key.pid), [0x00DA])
        let both = dongle + cable
        XCTAssertEqual(both[HIDDeviceSelection.controlInterfaceIndex(interfaces: both)!].pid, 0x00DA)
        // A different known mouse's dongle stays: it isn't this cable's mouse.
        let other: [HIDInterfaceInfo] = [
            .init(pid: 0x00C5, locationID: 0x3000000, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90, productName: "Razer DeathAdder V3 HyperSpeed"),
        ]
        XCTAssertEqual(HIDDeviceSelection.candidates(interfaces: both + other).map(\.key.pid), [0x00DA, 0x00C5])
        XCTAssertTrue(RazerDevices.isCable(0x00C4, ofDongle: 0x00C5), "same name on both rows")
        // When the cable doesn't answer, its dongle is what to open instead.
        XCTAssertEqual(HIDDeviceSelection.dongleIndex(ofCable: 0x00DA, interfaces: both).map { both[$0].pid }, 0x00DB)
        XCTAssertNil(HIDDeviceSelection.dongleIndex(ofCable: 0x00DA, interfaces: cable), "no dongle plugged in")
        XCTAssertNil(HIDDeviceSelection.dongleIndex(ofCable: 0x00C4, interfaces: both), "not that cable's dongle")
        XCTAssertFalse(RazerDevices.isCable(0x00DB, ofDongle: 0x00DA))
    }

    /// What `openCableOrItsDongle` does with the cable and its dongle, without IOHID.
    func testTheCableIsKeptUnlessTheDongleCanTakeOver() throws {
        var closed: [String] = []
        func open(cableAnswers: Bool, dongle: (() throws -> String)?) throws -> (device: String, onDongle: Bool) {
            try MouseController.openPreferringCable(cable: { "cable" }, dongle: dongle,
                                                    answers: { _ in cableAnswers }, close: { closed.append($0) })
        }
        struct Failed: Error {}
        let ok = try open(cableAnswers: true, dongle: { "dongle" })
        XCTAssertEqual(ok.device, "cable"); XCTAssertFalse(ok.onDongle)
        let alone = try open(cableAnswers: false, dongle: nil)
        XCTAssertEqual(alone.device, "cable", "no dongle: the cable is all there is")
        XCTAssertTrue(closed.isEmpty)
        let fellBack = try open(cableAnswers: false, dongle: { "dongle" })
        XCTAssertEqual(fellBack.device, "dongle"); XCTAssertTrue(fellBack.onDongle)
        XCTAssertEqual(closed, ["cable"])
        let stuck = try open(cableAnswers: false, dongle: { throw Failed() })
        XCTAssertEqual(stuck.device, "cable", "a dongle that won't open leaves the cable open")
        XCTAssertFalse(stuck.onDongle)
        XCTAssertEqual(closed, ["cable"])
    }

    func testCableAndDongleOfOneMouseAreLabelledByLink() {
        let cobra = [
            HIDDeviceSelection.Candidate(key: .init(pid: 0x00DB, locationID: 1), name: "Razer Cobra HyperSpeed", index: 0),
            HIDDeviceSelection.Candidate(key: .init(pid: 0x00DA, locationID: 2), name: "Razer Cobra HyperSpeed", index: 1),
        ]
        XCTAssertEqual(DeviceTestModel.deviceLabels(cobra),
                       ["Razer Cobra HyperSpeed (2.4 GHz)", "Razer Cobra HyperSpeed (Wired)"])
        let twoDongles = [
            HIDDeviceSelection.Candidate(key: .init(pid: 0x00DB, locationID: 1), name: "Razer Cobra HyperSpeed", index: 0),
            HIDDeviceSelection.Candidate(key: .init(pid: 0x00DB, locationID: 2), name: "Razer Cobra HyperSpeed", index: 1),
        ]
        XCTAssertEqual(DeviceTestModel.deviceLabels(twoDongles),
                       ["Razer Cobra HyperSpeed (2.4 GHz) 1", "Razer Cobra HyperSpeed (2.4 GHz) 2"])
    }

    func testTheHintNamesEveryDeviceAndTheOneUnderTest() {
        let two = [
            HIDDeviceSelection.Candidate(key: .init(pid: 0x007E, locationID: 1), name: "Razer Mouse Dock", index: 0),
            HIDDeviceSelection.Candidate(key: .init(pid: 0x0088, locationID: 2), name: "Razer Basilisk Ultimate Dongle", index: 1),
        ]
        XCTAssertEqual(DeviceTestModel.unplugHint(two, testing: "Razer Mouse Dock"),
                       "More than one Razer device that could be a mouse is plugged in: Razer Mouse Dock and Razer Basilisk Ultimate Dongle. For an accurate test, unplug all but the one you want to test. The test will run on Razer Mouse Dock.")
        let three = two + [HIDDeviceSelection.Candidate(key: .init(pid: 0x00C5, locationID: 3), name: "Razer DeathAdder V3 HyperSpeed", index: 2)]
        XCTAssertTrue(DeviceTestModel.unplugHint(three, testing: nil)
            .contains("Razer Mouse Dock, Razer Basilisk Ultimate Dongle, and Razer DeathAdder V3 HyperSpeed. For an accurate test, unplug all but the one you want to test."))
        XCTAssertFalse(DeviceTestModel.unplugHint(three, testing: nil).contains("will run on"))
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The Mouse Dock Pro's lighting is the lighting of the mouse on it. These pin how the
/// mouse's brightness answers decide what the app offers, and that the device test doesn't
/// fail a dock for carrying a mouse without lights.
final class DockedLightingTests: XCTestCase {
    private let dock = 0x00A4

    override func tearDown() {
        RazerDevices.forgetDockedLighting()
        super.tearDown()
    }

    /// Answers each LED's brightness read as `answers` says: a value, a refusal or a timeout.
    private final class Dock: DeviceProbeChannel {
        enum Answer { case value(UInt8), refuse, timeout }
        var answers: [UInt8: Answer] = [:]
        var otherwise = Answer.refuse
        private(set) var asked: [UInt8] = []

        func send(_ report: RazerReport) throws -> RazerReport {
            let led = report.arguments[1]
            asked.append(led)
            switch answers[led] ?? otherwise {
            case .value(let raw):
                var reply = report
                reply.status = RazerStatus.successful.rawValue
                reply.arguments[2] = raw
                return reply
            case .refuse: throw HIDDevice.HIDError.commandFailed
            case .timeout: throw HIDDevice.HIDError.timeout
            }
        }
        func sendWithRetry(_ report: RazerReport, attempts: Int) throws -> RazerReport { try send(report) }
    }

    // MARK: The probe

    func testAMouseThatAnswersIsLitOnTheGroupsItAnsweredOn() {
        let channel = Dock()
        channel.answers = [Razer.logoLed: .value(255), Razer.scrollLed: .value(128), Razer.zeroLed: .value(255)]
        XCTAssertEqual(DeviceProbe.dockedLighting(channel), .lit([Razer.logoLed, Razer.scrollLed, Razer.zeroLed]))
        XCTAssertEqual(channel.asked, DeviceProbe.dockedLightingLeds, "every group, once each")
    }

    func testAMouseThatRefusesEveryGroupIsUnlit() {
        // The Basilisk V4 HyperSpeed on the dock: every brightness read refused.
        XCTAssertEqual(DeviceProbe.dockedLighting(Dock()), .unlit)
    }

    func testAMouseLitOnlyOnItsSidesIsFound() {
        let channel = Dock()
        channel.answers = [Razer.leftSideLed: .value(200)]
        XCTAssertEqual(DeviceProbe.dockedLighting(channel), .lit([Razer.leftSideLed]))
    }

    func testASilentMouseIsUnknownAfterOneTimeout() {
        let channel = Dock()
        channel.otherwise = .timeout
        XCTAssertEqual(DeviceProbe.dockedLighting(channel), .unknown, "a sleeping mouse says nothing about its lights")
        XCTAssertEqual(channel.asked, [Razer.logoLed], "one timeout, not seven")
    }

    func testATimeoutOnOneGroupDoesNotHideTheOthers() {
        let channel = Dock()
        channel.answers = [Razer.logoLed: .refuse, Razer.underglowLed: .timeout]
        XCTAssertEqual(DeviceProbe.dockedLighting(channel), .unlit, "refusals were heard, so the mouse is unlit")
        channel.answers = [Razer.logoLed: .refuse, Razer.scrollLed: .timeout, Razer.backlightLed: .value(10)]
        XCTAssertEqual(DeviceProbe.dockedLighting(channel), .lit([Razer.backlightLed]))
    }

    func testAStaleStatusIsNeitherAnAnswerNorARefusal() {
        var stale = RazerCommands.getBrightness(led: Razer.logoLed)
        stale.status = 0x00
        XCTAssertEqual(DeviceProbe.dockedLighting([(Razer.logoLed, .success(stale))]), .unknown)
    }

    // MARK: What the registry hands out

    func testTheRowStandsUntilTheMouseHasAnswered() {
        XCTAssertNil(RazerDevices.dockedLightingLeds(pid: dock))
        XCTAssertTrue(RazerDevices.hasLighting(pid: dock))
        XCTAssertEqual(RazerDevices.brightnessLeds(pid: dock), [Razer.logoLed])
    }

    func testAnUnlitMouseHidesTheDocksLighting() {
        RazerDevices.learnDockedLighting(.unlit, pid: dock)
        XCTAssertFalse(RazerDevices.hasLighting(pid: dock))
        XCTAssertTrue(RazerDevices.info(pid: dock)!.hasLighting, "the row itself is unchanged")
    }

    func testALitMouseGivesItsOwnZones() {
        RazerDevices.learnDockedLighting(.lit([Razer.scrollLed, Razer.leftSideLed, Razer.zeroLed]), pid: dock)
        XCTAssertTrue(RazerDevices.hasLighting(pid: dock))
        XCTAssertEqual(RazerDevices.brightnessLed(pid: dock), Razer.scrollLed)
        XCTAssertEqual(RazerDevices.confirmedBrightnessLeds(pid: dock), [Razer.scrollLed],
                       "the others are best effort, so a zone that answers but isn't a light can't fail the slider")
        XCTAssertEqual(RazerDevices.brightnessLeds(pid: dock), [Razer.scrollLed, Razer.leftSideLed], "ZERO is no zone of its own")
    }

    func testOnlyZeroAnsweringStillGivesASlider() {
        RazerDevices.learnDockedLighting(.lit([Razer.zeroLed]), pid: dock)
        XCTAssertEqual(RazerDevices.brightnessLeds(pid: dock), [Razer.zeroLed])
    }

    func testUnknownForgetsWhatWasLearned() {
        RazerDevices.learnDockedLighting(.unlit, pid: dock)
        RazerDevices.learnDockedLighting(.unknown, pid: dock)
        XCTAssertNil(RazerDevices.dockedLightingLeds(pid: dock))
        XCTAssertTrue(RazerDevices.hasLighting(pid: dock))
    }

    func testOtherPidsIgnoreTheProbe() {
        RazerDevices.learnDockedLighting(.unlit, pid: 0x00DB)
        XCTAssertNil(RazerDevices.dockedLightingLeds(pid: 0x00DB))
        XCTAssertTrue(RazerDevices.hasLighting(pid: 0x00DB))
    }

    // MARK: The device test

    func testIdentifyPassesADockWhoseMouseHasNoLights() {
        let mouse = FakeMouse()
        mouse.refuse = { $0.commandClass == 0x0F }
        let (record, _) = DeviceTestSteps.identify(mouse, registry: RazerDevices.info(pid: dock))
        XCTAssertEqual(record.outcome, .passed)
        XCTAssertNil(record.data?.lightingAttempts.first(where: \.answered))
    }

    func testIdentifyStillFailsADockWhoseMouseIsSilent() {
        // Asleep on the dock: every lighting id times out. Nothing was refused, so nothing
        // says the mouse has no lights.
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x0F: []]
        let (record, _) = DeviceTestSteps.identify(mouse, registry: RazerDevices.info(pid: dock))
        XCTAssertEqual(record.outcome, .failed)
    }

    func testIdentifyStillFailsADockWhoseOwnIdIsSilent() {
        // Another id refuses, but 0x1F, the one the row lights with, times out.
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x0F: [0x3F]]
        mouse.refuse = { $0.commandClass == 0x0F } // reached only by 0x3F
        let (record, _) = DeviceTestSteps.identify(mouse, registry: RazerDevices.info(pid: dock))
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertNil(record.data?.lightingAttempts.first(where: \.answered))
    }

    func testTheProbeGivesUpWhenATapIsWaiting() {
        let dock = Dock()
        dock.otherwise = .refuse
        var asked = 0
        let found = DeviceProbe.dockedLighting(dock, shouldStop: { asked += 1; return asked > 2 })
        XCTAssertEqual(found, .unknown)
        XCTAssertEqual(dock.asked.count, 2)
    }

    func testIdentifyPassesADockWhoseMouseAnswersOnItsId() {
        let (record, _) = DeviceTestSteps.identify(FakeMouse(), registry: RazerDevices.info(pid: dock))
        XCTAssertEqual(record.outcome, .passed)
        XCTAssertEqual(record.data?.lightingId, 0x1F)
    }

    func testIdentifyStillFailsADockWhoseMouseAnswersOnAnotherId() {
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x0F: [0x3F]]
        let (record, _) = DeviceTestSteps.identify(mouse, registry: RazerDevices.info(pid: dock))
        XCTAssertEqual(record.outcome, .failed)
    }

    func testIdentifyStillFailsAMouseWhoseLightsRefuse() {
        // Not a dock: a lit row that refuses lighting is still a regression.
        let mouse = FakeMouse()
        mouse.refuse = { $0.commandClass == 0x0F }
        let (record, _) = DeviceTestSteps.identify(mouse, registry: RazerDevices.info(pid: 0x00DB))
        XCTAssertEqual(record.outcome, .failed)
    }

    // MARK: When a poll asks again

    func testAPollAsksWhileNothingIsKnown() {
        XCTAssertTrue(RazerDevices.shouldReprobeDock(known: nil, brightnessAnswered: false, pollsSinceProbe: 1))
    }

    func testALitMouseIsAskedAgainOnlyWhenTheReadFails() {
        XCTAssertFalse(RazerDevices.shouldReprobeDock(known: [Razer.logoLed], brightnessAnswered: true, pollsSinceProbe: 100))
        XCTAssertTrue(RazerDevices.shouldReprobeDock(known: [Razer.logoLed], brightnessAnswered: false, pollsSinceProbe: 1))
    }

    /// A lit mouse swapped in may answer only on groups the poll's one read doesn't ask.
    func testAnUnlitMouseIsAskedAgainNowAndThen() {
        XCTAssertTrue(RazerDevices.shouldReprobeDock(known: [], brightnessAnswered: true, pollsSinceProbe: 1))
        XCTAssertFalse(RazerDevices.shouldReprobeDock(known: [], brightnessAnswered: false,
                                                      pollsSinceProbe: RazerDevices.dockUnlitReprobePolls - 1))
        XCTAssertTrue(RazerDevices.shouldReprobeDock(known: [], brightnessAnswered: false,
                                                     pollsSinceProbe: RazerDevices.dockUnlitReprobePolls))
    }
}

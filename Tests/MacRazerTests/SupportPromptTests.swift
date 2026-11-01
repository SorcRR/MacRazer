// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class SupportPromptPolicyTests: XCTestCase {
    /// Not in the registry at all, so never supported.
    private let unknown = 0xFFFE
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var supported: Int { RazerDevices.known.first { $0.fullySupported }!.pid }

    private func ask(_ pid: Int, _ record: SupportPromptRecord = .init(), enabled: Bool = true,
                     at time: Date? = nil) -> Bool {
        SupportPromptPolicy.shouldAsk(pid: pid, record: record, enabled: enabled, now: time ?? now)
    }

    func testAsksForUnknownAndUnverifiedModels() throws {
        XCTAssertTrue(ask(unknown))
        guard let unverified = RazerDevices.known.first(where: { !$0.fullySupported })?.pid else {
            throw XCTSkip("every registry row is verified")
        }
        XCTAssertTrue(ask(unverified), "a known row that isn't verified needs a report just as much")
    }

    func testNeverAsksForASupportedModel() {
        XCTAssertFalse(ask(supported))
        XCTAssertFalse(SupportPromptPolicy.showsCard(pid: supported, record: .init(), enabled: true))
    }

    /// Fully supported on this link isn't the end of it: a mouse whose other way of connecting
    /// still needs a report is asked about too. One with every link verified isn't.
    func testAsksAboutAnotherLinkStillToTest() throws {
        // Any verified row with another link still to test, so verifying one link's row later
        // doesn't break this.
        guard let verifiedHere = RazerDevices.known.first(where: {
            $0.fullySupported && !RazerDevices.linksToTest(besides: $0.pid).isEmpty
        })?.pid else { throw XCTSkip("every verified row has all its links verified") }
        XCTAssertTrue(ask(verifiedHere))
        XCTAssertTrue(SupportPromptPolicy.showsCard(pid: verifiedHere, record: .init(), enabled: true))
        XCTAssertFalse(ask(0x00DB), "the Cobra HyperSpeed is verified on every link")
        XCTAssertFalse(ask(0x0062), "the Atheris has no cable mode to ask about")
    }

    func testSettingOffSilencesBoth() {
        XCTAssertFalse(ask(unknown, enabled: false))
        XCTAssertFalse(SupportPromptPolicy.showsCard(pid: unknown, record: .init(), enabled: false))
    }

    func testRemindsOnceAfterAWeek() {
        let first = SupportPromptRecord(timesAsked: 1, lastAsked: now)
        XCTAssertFalse(ask(unknown, first, at: now.addingTimeInterval(60)), "not again on the next tick")
        XCTAssertFalse(ask(unknown, first, at: now.addingTimeInterval(SupportPromptPolicy.reminderAfter - 1)))
        XCTAssertTrue(ask(unknown, first, at: now.addingTimeInterval(SupportPromptPolicy.reminderAfter)))

        let second = SupportPromptRecord(timesAsked: 2, lastAsked: now)
        XCTAssertFalse(ask(unknown, second, at: now.addingTimeInterval(365 * 24 * 3600)),
                       "the window stops after the reminder")
        XCTAssertTrue(SupportPromptPolicy.showsCard(pid: unknown, record: second, enabled: true),
                      "the popover card stays")
    }

    func testDeclinedOrReportedEndsBoth() {
        for record in [SupportPromptRecord(declined: true), SupportPromptRecord(reported: true)] {
            XCTAssertFalse(ask(unknown, record))
            XCTAssertFalse(SupportPromptPolicy.showsCard(pid: unknown, record: record, enabled: true))
        }
    }
}

/// What the prompt and the popover card say for each kind of mouse.
@MainActor
final class SupportPromptWordingTests: XCTestCase {
    func testCardText() {
        XCTAssertEqual(SupportPromptView.cardText(pid: 0xFFFE).title, "Help us support this mouse")
        let partly = SupportPromptView.cardText(pid: 0x00E3)
        XCTAssertEqual(partly.title, "Help finish support for this mouse")
        XCTAssertTrue(partly.detail.hasPrefix("Polling rate still needs testing"), partly.detail)
        let links = SupportPromptView.cardText(pid: 0x0090)
        XCTAssertEqual(links.title, "Test its other connection")
        XCTAssertTrue(links.detail.contains("its cable"), links.detail)
    }

    /// Over Bluetooth there's no cable or dongle in to unplug first.
    func testLinkTextFromBluetooth() {
        typealias Link = RazerDevices.LinkToTest
        let dongle = DeviceTestView.linkText(Link(connection: .wirelessDongle, missing: [.dpi]), from: .bluetooth)
        XCTAssertEqual(dongle, "On its dongle, this mouse still needs testing: DPI. To help, switch the mouse to its dongle and run the test.")
        let cable = DeviceTestView.linkText(Link(connection: .wired, missing: nil), from: .bluetooth)
        XCTAssertFalse(cable.contains("unplug"), cable)
        XCTAssertTrue(DeviceTestView.linkText(Link(connection: .wirelessDongle, missing: nil)).contains("unplug the cable"))
    }

    func testLinkSummaryNamesEveryLink() {
        XCTAssertEqual(SupportPromptView.linkSummary([]), "Verified on this connection.")
        typealias Link = RazerDevices.LinkToTest
        XCTAssertEqual(SupportPromptView.linkSummary([Link(connection: .wired, missing: nil),
                                                      Link(connection: .bluetooth, missing: [.dpi])]),
                       "Verified on this connection. If your mouse also uses its cable and Bluetooth, a test there helps.")
    }
}

@MainActor
final class SupportPromptStoreTests: XCTestCase {
    nonisolated private static let suite = "SupportPromptStoreTests"
    private var defaults: UserDefaults { UserDefaults(suiteName: Self.suite)! }
    private let pid = 0xFFFE

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: Self.suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    func testOnByDefault() {
        XCTAssertTrue(SupportPrompt(defaults: defaults).isEnabled)
    }

    func testRecordsSurviveARelaunch() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let first = SupportPrompt(defaults: defaults)
        first.markAsked(pid: pid, now: at)
        first.isEnabled = false

        let second = SupportPrompt(defaults: defaults)
        XCTAssertEqual(second.record(pid: pid), SupportPromptRecord(timesAsked: 1, lastAsked: at))
        XCTAssertFalse(second.isEnabled)
    }

    func testAskingIsPerModel() {
        let prompt = SupportPrompt(defaults: defaults)
        prompt.markAsked(pid: pid)
        XCTAssertFalse(prompt.shouldAsk(pid: pid))
        XCTAssertTrue(prompt.shouldAsk(pid: pid - 1), "another link or model is a separate ask")
    }

    func testReportedHidesTheCard() {
        let prompt = SupportPrompt(defaults: defaults)
        XCTAssertTrue(prompt.showsCard(pid: pid))
        prompt.markReported(pid: pid)
        XCTAssertFalse(prompt.showsCard(pid: pid))
        XCTAssertFalse(prompt.shouldAsk(pid: pid))
    }

    func testUnreadableRecordsStartOver() {
        defaults.set(Data("not json".utf8), forKey: SupportPrompt.recordsKey)
        XCTAssertTrue(SupportPrompt(defaults: defaults).shouldAsk(pid: pid))
    }

    // MARK: Reports

    /// A test at the review screen for the preview mouse, a Cobra HyperSpeed on the dongle.
    private func reviewedTest() -> DeviceTestModel {
        let model = DeviceTestModel(controller: MouseController(), permissions: PermissionsModel(),
                                    reportEndpoint: nil)
        model.loadPreview(.review, pid: 0x00DB, ranSteps: true)
        return model
    }

    func testSendingAReportMarksItsModel() {
        let prompt = SupportPrompt(defaults: defaults)
        let model = reviewedTest()
        let tracking = prompt.trackReports(from: model)
        XCTAssertFalse(prompt.record(pid: 0x00DB).reported, "reaching the review is not a report")
        model.previewSendState(.failed(.tooMany))
        XCTAssertFalse(prompt.record(pid: 0x00DB).reported, "a failed send is not a report")
        model.previewSendState(.sent)
        XCTAssertTrue(prompt.record(pid: 0x00DB).reported)
        tracking.cancel()
    }

    func testResetAfterSendingKeepsTheMark() {
        let prompt = SupportPrompt(defaults: defaults)
        let model = reviewedTest()
        let tracking = prompt.trackReports(from: model)
        model.previewSendState(.sent)
        model.reset()
        XCTAssertTrue(prompt.record(pid: 0x00DB).reported)
        XCTAssertEqual(prompt.records.count, 1, "the reset must not mark some other model")
        tracking.cancel()
    }
}

final class SupportPromptMouseWithoutAccessTests: XCTestCase {
    private let unknown = HIDDevice.USBMouse(pid: 0xFFFE, name: "Razer DeathAdder V3 Pro")
    private var supported: HIDDevice.USBMouse {
        let info = RazerDevices.known.first { $0.fullySupported }!
        return HIDDevice.USBMouse(pid: info.pid, name: info.name)
    }

    func testFindsAnUnverifiedMouseWithoutAccess() {
        XCTAssertEqual(SupportPrompt.mouseWithoutAccess(among: [unknown], accessGranted: false),
                       UnsupportedMouse(pid: 0xFFFE, name: "Razer DeathAdder V3 Pro", canControl: false))
    }

    func testSkipsASupportedMouseForTheUnverifiedOne() {
        XCTAssertEqual(SupportPrompt.mouseWithoutAccess(among: [supported, unknown], accessGranted: false)?.pid,
                       0xFFFE)
        XCTAssertNil(SupportPrompt.mouseWithoutAccess(among: [supported], accessGranted: false),
                     "the setup window covers a supported mouse")
    }

    func testNothingOnceAccessIsGranted() {
        XCTAssertNil(SupportPrompt.mouseWithoutAccess(among: [unknown], accessGranted: true),
                     "with access the mouse connects, and the connected path asks instead")
    }
}

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
        // A USB row with nothing else to ask about, so it's its own link that asks.
        guard let unverified = RazerDevices.known.first(where: {
            !$0.fullySupported && $0.connection != .bluetooth && RazerDevices.linksToTest(besides: $0.pid).isEmpty
        })?.pid else {
            throw XCTSkip("no unverified USB row without other links to test")
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
        let partly = SupportPromptView.cardText(pid: 0x0034)
        XCTAssertEqual(partly.title, "Help finish support for this mouse")
        XCTAssertTrue(partly.detail.hasPrefix("Lighting still needs testing"), partly.detail)
        let links = SupportPromptView.cardText(pid: 0x00C3)
        XCTAssertEqual(links.title, "Test its other connection")
        XCTAssertTrue(links.detail.contains("its cable"), links.detail)
    }

    /// On Bluetooth the test only reads. The Basilisk V3 Pro 35K there lacks only what it would
    /// have to set, so it's asked about its cable, never sent to a test that can't help.
    func testBluetoothRowMissingOnlySettingsPointsAtTheCable() {
        XCTAssertTrue(RazerDevices.needsReport(pid: 0x00CE), "its cable still has lighting to confirm")
        let card = SupportPromptView.card(pid: 0x00CE)
        XCTAssertTrue(card.otherLinksOnly, "no test to run on Bluetooth")
        XCTAssertEqual(card.title, "Test its other connection", "its cable: the dongle is fully supported")
        XCTAssertTrue(card.detail.contains("cable"), card.detail)
        XCTAssertFalse(SupportPromptView.card(pid: 0x00CC).otherLinksOnly, "a USB row still runs its own test")
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

/// The one check-up ask for a fully supported mouse, for someone new to the app.
final class CheckupPolicyTests: XCTestCase {
    /// The Cobra HyperSpeed: verified on every link, over its dongle.
    private let everyLinkVerified = 0x00DB
    private let unknown = 0xFFFE
    /// Today is the third day of use: two before it.
    private let third = CheckupPolicy.daysBefore + 1

    private func ask(_ pid: Int, daysUsed: Int?, asked: Bool = false, _ record: SupportPromptRecord = .init(),
                     enabled: Bool = true) -> Bool {
        CheckupPolicy.shouldAsk(pid: pid, daysUsed: daysUsed, asked: asked, record: record, enabled: enabled)
    }

    func testAsksOnTheDayAfterTwoDaysOfUse() {
        XCTAssertFalse(ask(everyLinkVerified, daysUsed: 1), "not on the first day")
        XCTAssertFalse(ask(everyLinkVerified, daysUsed: 2), "not on the second")
        XCTAssertTrue(ask(everyLinkVerified, daysUsed: third))
    }

    func testNeverForSomeoneWhoUpdated() {
        XCTAssertFalse(ask(everyLinkVerified, daysUsed: nil), "no clock: the app ran before this version")
    }

    func testOnlyOnce() {
        XCTAssertFalse(ask(everyLinkVerified, daysUsed: third, asked: true))
    }

    func testOnlyForAMouseNoReportWouldHelp() throws {
        XCTAssertFalse(ask(unknown, daysUsed: third), "an unknown mouse gets the support prompt")
        guard let verifiedHere = RazerDevices.known.first(where: {
            $0.fullySupported && !RazerDevices.linksToTest(besides: $0.pid).isEmpty
        })?.pid else { throw XCTSkip("every verified row has all its links verified") }
        XCTAssertFalse(ask(verifiedHere, daysUsed: third), "another link still needs a report")
    }

    func testNotOverBluetooth() throws {
        guard let bluetooth = RazerDevices.known.first(where: {
            $0.connection == .bluetooth && $0.fullySupported && !RazerDevices.needsReport(pid: $0.pid)
        })?.pid else { throw XCTSkip("no fully supported Bluetooth row") }
        XCTAssertFalse(ask(bluetooth, daysUsed: third), "the test there only reads")
    }

    func testSettingOffDeclinedOrReportedSilenceIt() {
        XCTAssertFalse(ask(everyLinkVerified, daysUsed: third, enabled: false))
        XCTAssertFalse(ask(everyLinkVerified, daysUsed: third, SupportPromptRecord(declined: true)))
        XCTAssertFalse(ask(everyLinkVerified, daysUsed: third, SupportPromptRecord(reported: true)))
    }
}

@MainActor
final class CheckupStorageTests: XCTestCase {
    private static let suite = "MacRazerTests.Checkup"
    private var defaults: UserDefaults { UserDefaults(suiteName: Self.suite)! }
    private let pid = 0x00DB
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: Self.suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    private func use(_ prompt: SupportPrompt, at time: Date) { prompt.noteUse(now: time, calendar: calendar) }

    func testCountsSeparateDaysOfUse() {
        let prompt = SupportPrompt(defaults: defaults)
        prompt.noteLaunch(firstRun: true, now: start)
        use(prompt, at: start)
        use(prompt, at: start.addingTimeInterval(60))
        use(prompt, at: start.addingTimeInterval(3600))
        XCTAssertFalse(prompt.shouldAskCheckup(pid: pid), "many ticks on one day are one day")
        // A week away doesn't count: only the days it ran.
        use(prompt, at: start.addingTimeInterval(7 * day))
        XCTAssertFalse(prompt.shouldAskCheckup(pid: pid), "two days of use so far")
        use(prompt, at: start.addingTimeInterval(9 * day))
        XCTAssertTrue(prompt.shouldAskCheckup(pid: pid), "the third day of use")
    }

    func testFirstRunStartsTheClockOnce() {
        let prompt = SupportPrompt(defaults: defaults)
        prompt.noteLaunch(firstRun: true, now: start)
        prompt.noteLaunch(firstRun: true, now: start.addingTimeInterval(day))
        XCTAssertEqual(defaults.object(forKey: SupportPrompt.checkupFirstUseKey) as? Date, start)
    }

    func testAnUpdateNeverStartsIt() {
        let prompt = SupportPrompt(defaults: defaults)
        prompt.noteLaunch(firstRun: false, now: start)
        for n in 0..<10 { use(prompt, at: start.addingTimeInterval(Double(n) * day)) }
        XCTAssertFalse(prompt.shouldAskCheckup(pid: pid))
        XCTAssertEqual(defaults.integer(forKey: SupportPrompt.checkupDaysKey), 0, "no days counted without a clock")
    }

    func testAskedSurvivesARelaunch() {
        let first = SupportPrompt(defaults: defaults)
        first.noteLaunch(firstRun: true, now: start)
        for n in 0..<3 { use(first, at: start.addingTimeInterval(Double(n) * day)) }
        first.markCheckupAsked()
        let second = SupportPrompt(defaults: defaults)
        XCTAssertFalse(second.shouldAskCheckup(pid: pid))
        XCTAssertEqual(second.record(pid: pid), SupportPromptRecord(), "the per-model record is left alone")
    }

    func testFirstRunNeedsNoEarlierKeys() {
        XCTAssertTrue(UpdateChecker.isFirstRun(defaults: defaults))
        defaults.set("0.10.0", forKey: "lastRunVersion")
        XCTAssertFalse(UpdateChecker.isFirstRun(defaults: defaults))
    }
}

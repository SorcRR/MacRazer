// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CoreGraphics
import XCTest
@testable import MacRazer

/// What the device test's button step looks for besides the buttons: Razer's software and
/// other apps that can take them, and the keys a side button sends.
final class RemapCheckTests: XCTestCase {
    typealias Key = DeviceReport.KeyPress

    // MARK: Razer software

    func testRazerProcessesAreNamedByTheirApp() {
        XCTAssertEqual(RemapSoftware.razerName(executablePath: "/Applications/Razer Synapse.app/Contents/MacOS/Razer Synapse"),
                       "Razer Synapse")
        XCTAssertEqual(RemapSoftware.razerName(
            executablePath: "/Applications/Razer Synapse.app/Contents/Library/LoginItems/RazerAppEngine.app/Contents/MacOS/RazerAppEngine"),
                       "Razer Synapse", "a helper inside the app goes by the app")
        XCTAssertEqual(RemapSoftware.razerName(executablePath: "/Library/Application Support/Razer/RzUpdater"), "RzUpdater",
                       "a daemon outside any app goes by its executable")
    }

    func testOtherProcessesAndMacRazerItselfDontMatch() {
        XCTAssertNil(RemapSoftware.razerName(executablePath: "/Applications/MacRazer.app/Contents/MacOS/MacRazer"))
        XCTAssertNil(RemapSoftware.razerName(executablePath: "/Users/me/gitrepos/razer-cobra-mac/.build/debug/MacRazer"))
        XCTAssertNil(RemapSoftware.razerName(executablePath: "/Applications/Safari.app/Contents/MacOS/Safari"))
        XCTAssertNil(RemapSoftware.razerName(executablePath: "/System/Library/Razer/whatever"), "macOS's own folders")
        XCTAssertNil(RemapSoftware.razerName(executablePath: "/Users/me/gitrepos/razer-cobra-mac/.build/debug/swift-build"),
                     "a folder that only has the word in it")
        XCTAssertNil(RemapSoftware.razerName(executablePath: "/Users/frazer/bin/tool"))
        XCTAssertEqual(RemapSoftware.razerName(executablePath: "/Library/PrivilegedHelperTools/com.razer.rzupdater"),
                       "com.razer.rzupdater")
    }

    func testNamesAreDistinctSortedAndCapped() {
        XCTAssertEqual(RemapSoftware.tidy(["B", "A", "B"]), ["A", "B"])
        let many = (0..<40).map { String(format: "App %02d", $0) }
        XCTAssertEqual(RemapSoftware.tidy(many).count, RemapSoftware.maxNames)
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(RemapSoftware.tidy([long]).first?.count, RemapSoftware.maxNameLength)
    }

    func testTheWarningNamesWhatCanTakeTheButtons() {
        XCTAssertNil(DeviceTestView.softwareWarning(.init()))
        let razer = DeviceTestView.softwareWarning(.init(razer: ["Razer Synapse", "RzUpdater"]))
        XCTAssertEqual(razer, "Razer software is running: Razer Synapse and RzUpdater. It can take over the side buttons, so MacRazer may not see them. Quit it and press the buttons again.")
        XCTAssertEqual(DeviceTestView.softwareWarning(.init(mouseTaps: ["BetterTouchTool"])),
                       "BetterTouchTool also watches mouse buttons and can catch them before MacRazer does.")
        for text in [razer!] { XCTAssertFalse(text.contains("\u{2014}"), "no em dashes in user-facing text") }
    }

    // MARK: Keys

    func testAKeyIsRecordedOnceWithItsModifiers() {
        var log = KeystrokeLog()
        log.keyDown(keyCode: 9, flags: .maskControl, autorepeat: false, postedBy: nil)
        log.keyDown(keyCode: 9, flags: .maskControl, autorepeat: true, postedBy: nil)
        log.keyDown(keyCode: 9, flags: .maskControl, autorepeat: false, postedBy: nil)
        XCTAssertEqual(log.sorted, [Key(keyCode: 9, modifiers: ["control"], postedBy: nil)])
    }

    func testAKeyPostedBySoftwareIsKeptApart() {
        var log = KeystrokeLog()
        log.keyDown(keyCode: 8, flags: .maskCommand, autorepeat: false, postedBy: nil)
        log.keyDown(keyCode: 8, flags: .maskCommand, autorepeat: false, postedBy: "Razer Synapse")
        XCTAssertEqual(log.sorted.map(\.postedBy), [nil, "Razer Synapse"])
    }

    func testAModifierAloneIsRecordedOnRelease() {
        var log = KeystrokeLog()
        log.flagsChanged(keyCode: 56, flags: .maskShift, postedBy: nil)
        XCTAssertTrue(log.keys.isEmpty, "not until it comes back up")
        log.flagsChanged(keyCode: 56, flags: [], postedBy: nil)
        XCTAssertEqual(log.sorted, [Key(keyCode: 56, modifiers: ["shift"], postedBy: nil)])
    }

    func testAModifierHeldForAShortcutIsNotAlsoRecordedAlone() {
        var log = KeystrokeLog()
        log.flagsChanged(keyCode: 59, flags: .maskControl, postedBy: nil)
        log.keyDown(keyCode: 8, flags: .maskControl, autorepeat: false, postedBy: nil)
        log.flagsChanged(keyCode: 59, flags: [], postedBy: nil)
        XCTAssertEqual(log.sorted, [Key(keyCode: 8, modifiers: ["control"], postedBy: nil)])
    }

    func testFnIsLeftOutAndModifiersKeepMenuOrder() {
        let flags: CGEventFlags = [.maskSecondaryFn, .maskCommand, .maskShift, .maskAlternate, .maskControl]
        XCTAssertEqual(KeystrokeLog.modifiers(flags), ["control", "option", "shift", "command"])
    }

    func testTheLogStopsAtItsCap() {
        var log = KeystrokeLog()
        for code in 0..<(KeystrokeLog.maxKeys + 10) { log.keyDown(keyCode: code, flags: [], autorepeat: false, postedBy: nil) }
        XCTAssertEqual(log.keys.count, KeystrokeLog.maxKeys)
        // A key already in the log still counts as seen.
        log.keyDown(keyCode: 0, flags: [], autorepeat: false, postedBy: nil)
        XCTAssertEqual(log.keys.count, KeystrokeLog.maxKeys)
    }

    func testKeysReadTheWayMacOSWritesThem() {
        XCTAssertEqual(Key(keyCode: 9, modifiers: ["control"]).displayName, "⌃V")
        XCTAssertEqual(Key(keyCode: 21, modifiers: ["shift", "command"]).displayName, "⇧⌘4")
        XCTAssertEqual(Key(keyCode: 56, modifiers: ["shift"]).displayName, "Shift", "a modifier alone is just its name")
        XCTAssertEqual(Key(keyCode: 200, modifiers: []).displayName, "Key 200")
    }

    // MARK: The report

    /// A report from before schema 6 still reads: everything new is optional.
    func testASchema5ReportStillDecodes() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(DeviceReportOutput.json(DeviceReportSenderTests.fullReport(), forPublic: false).utf8)) as? [String: Any])
        json["schemaVersion"] = 5
        json["software"] = nil
        var buttons = try XCTUnwrap(json["buttons"] as? [String: Any])
        buttons["data"] = ["seen": ["09:04"]]
        json["buttons"] = buttons
        let report = try JSONDecoder().decode(DeviceReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(report.software)
        XCTAssertNil(report.buttons.data?.keys)
        XCTAssertEqual(report.buttons.data?.seen, ["09:04"])
    }

    func testTheIssueSummaryNamesTheSoftwareAndKeys() {
        let summary = DeviceReportOutput.summary(DeviceReportSenderTests.fullReport())
        XCTAssertTrue(summary.contains("Running, can take the buttons: Razer Synapse, RzEngineMonService and 1 other app"), summary)
        XCTAssertFalse(summary.contains("BetterTouchTool"), "the issue is public: only Razer's apps are named")
        XCTAssertTrue(summary.contains("Keys recorded: "), summary)
    }

    /// A GitHub issue names Razer's apps and counts the rest. The report Send emails keeps
    /// every name.
    func testOnlyThePublicCopyLeavesOtherAppsOut() throws {
        var report = DeviceReportSenderTests.fullReport()
        report.software = .init(razer: ["Razer Synapse"], mouseTaps: ["Razer Synapse", "BetterTouchTool", "Karabiner"])
        report.buttons.data?.keys = [
            Key(keyCode: 8, modifiers: ["command"], postedBy: "Razer Synapse"),
            Key(keyCode: 9, modifiers: ["command"], postedBy: "BetterTouchTool"),
            Key(keyCode: 9, modifiers: ["command"], postedBy: "Karabiner"),
        ]

        let sent = DeviceReportOutput.json(report, forPublic: false)
        XCTAssertTrue(sent.contains("BetterTouchTool") && sent.contains("Karabiner"))

        let publicJSON = DeviceReportOutput.json(report, forPublic: true)
        XCTAssertFalse(publicJSON.contains("BetterTouchTool") || publicJSON.contains("Karabiner"), publicJSON)
        let copy = try JSONDecoder().decode(DeviceReport.self, from: Data(publicJSON.utf8))
        XCTAssertEqual(copy.software, .init(razer: ["Razer Synapse"], mouseTaps: ["Razer Synapse"], otherApps: 2))
        XCTAssertEqual(copy.buttons.data?.keys, [
            Key(keyCode: 8, modifiers: ["command"], postedBy: "Razer Synapse"),
            Key(keyCode: 9, modifiers: ["command"], postedBy: DeviceReportOutput.anotherApp),
        ], "two apps' ⌘V reads as one")
        XCTAssertEqual(DeviceReportOutput.publicCopy(DeviceReportOutput.publicCopy(report)).software?.otherApps, 2,
                       "a second pass keeps the count")
        XCTAssertNil(copy.replyEmail)
    }

    // MARK: Keys alone

    /// Keys alone don't pass the button step: they may be the keyboard. They stay in the report.
    func testKeysAloneLeaveTheButtonStepUnconfirmed() {
        let keys = [Key(keyCode: 9, modifiers: ["control"])]
        let keysOnly = DeviceTestModel.buttonsRecord(seen: [], keys: keys)
        XCTAssertEqual(keysOnly.outcome, .skipped)
        XCTAssertEqual(keysOnly.data?.keys, keys)
        XCTAssertEqual(keysOnly.error, DeviceTestModel.keysOnlyNote)

        let both = DeviceTestModel.buttonsRecord(seen: ["09:04"], keys: keys)
        XCTAssertEqual(both.outcome, .passed)
        XCTAssertNil(both.error)
        XCTAssertEqual(DeviceTestModel.buttonsRecord(seen: ["07:1e"], keys: nil).outcome, .passed,
                       "a side key the mouse itself types is the mouse")
        XCTAssertEqual(DeviceTestModel.buttonsRecord(seen: [], keys: nil).outcome, .skipped)
        XCTAssertNil(DeviceTestModel.buttonsRecord(seen: [], keys: []).error)

        var report = DeviceReportSenderTests.fullReport()
        report.buttons = keysOnly
        XCTAssertTrue(DeviceReportOutput.summary(report).contains("Keys only, no mouse buttons: ⌃V"))
    }

    // MARK: The tap

    /// The tap holds the capture unretained, so dropping it ends the capture. Started or
    /// refused (no Input Monitoring on CI), it must not keep itself alive.
    func testAKeystrokeCaptureEndsWhenItsOwnerDropsIt() {
        weak var weakCapture: KeystrokeCapture?
        autoreleasepool {
            let capture = KeystrokeCapture { _ in }
            weakCapture = capture
            _ = capture.start()
        }
        XCTAssertNil(weakCapture)
    }

    // MARK: The model

    /// Recording keys is off on every new run, and turning it off clears what it held.
    @MainActor
    func testRecordingKeysStartsOffAndResets() {
        let model = DeviceTestModel(controller: MouseController(), permissions: PermissionsModel(), reportEndpoint: nil)
        XCTAssertFalse(model.recordKeys)
        // Not on the button step, so nothing starts listening.
        model.recordKeys = true
        XCTAssertNil(model.keyCaptureProblem)
        model.reset()
        XCTAssertFalse(model.recordKeys)
        XCTAssertTrue(model.keysSeen.isEmpty)
        XCTAssertEqual(model.software, .init())
    }
}

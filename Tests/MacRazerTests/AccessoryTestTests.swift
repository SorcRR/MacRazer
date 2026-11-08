// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The lighting test for keyboards and mousepads: the mouse test's Identify and Lighting
/// steps, pointed at an accessory's own id and LEDs, and the report they make.
final class AccessoryTestTests: XCTestCase {
    /// A FakeMouse that also keeps every report sent, with the id it carried.
    private final class Spy: TransactionChannel {
        let base = FakeMouse()
        private(set) var sent: [(report: RazerReport, id: UInt8?)] = []
        func send(_ report: RazerReport) throws -> RazerReport { try send(report, transactionId: nil) }
        func sendWithRetry(_ report: RazerReport, attempts: Int) throws -> RazerReport {
            try sendWithRetry(report, attempts: attempts, transactionId: nil)
        }
        func send(_ report: RazerReport, transactionId: UInt8?) throws -> RazerReport {
            sent.append((report, transactionId))
            return try base.send(report, transactionId: transactionId)
        }
        func sendWithRetry(_ report: RazerReport, attempts: Int, transactionId: UInt8?) throws -> RazerReport {
            sent.append((report, transactionId))
            return try base.sendWithRetry(report, attempts: attempts, transactionId: transactionId)
        }
    }

    /// The Ornata V3: 0x1F, effects and brightness on BACKLIGHT.
    private let ornata = RazerAccessories.info(pid: 0x02A1)!

    /// A keyboard lit only on BACKLIGHT, answering lighting commands on `id` alone.
    private func keyboard(answering id: UInt8, brightness: UInt8 = 200) -> Spy {
        let spy = Spy()
        spy.base.acceptedIds = [0x0F: [id]]
        spy.base.holds(RazerCommands.setBrightness(brightness, led: Razer.backlightLed))
        spy.base.refuse = { $0.commandClass == 0x0F && $0.commandId & 0x7F == 0x04 && $0.arguments[1] != Razer.backlightLed }
        return spy
    }

    func testIdentifyPassesWhenTheModelsOwnIdAnswers() {
        let (record, sweep) = DeviceTestSteps.identifyAccessory(keyboard(answering: 0x1F), info: ornata)
        XCTAssertEqual(record.outcome, .passed)
        XCTAssertEqual(record.data?.lightingId, 0x1F)
        XCTAssertEqual(sweep?.compactMap { (try? $0.result.get()) != nil ? $0.name : nil }, ["BACKLIGHT"])
    }

    func testIdentifyFailsWhenOnlyAnotherIdAnswers() {
        // The card stamps 0x1F on everything: a keyboard that answers 0x3F alone means the
        // row is wrong, which is what the report has to say.
        let (record, _) = DeviceTestSteps.identifyAccessory(keyboard(answering: 0x3F), info: ornata)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.data?.lightingId, 0x3F, "still finds the id that works")
    }

    func testLightingRunsOnTheAccessorysLedsAndPutsThemBack() throws {
        let spy = keyboard(answering: 0x1F)
        let restore = RazerAccessories.report(for: .spectrum, color: RGB(r: 0, g: 0, b: 0), on: ornata)
        var waits: [Double] = []
        var (identify, lighting) = DeviceTestSteps.accessoryLighting(spy, info: ornata, restoreEffect: restore,
                                                                     seconds: 3, wait: { waits.append($0) })
        XCTAssertEqual(identify.outcome, .passed)
        XCTAssertEqual(waits, [3, 3], "dark, then red")
        XCTAssertEqual(lighting.data?.groups, ["BACKLIGHT": 200])
        XCTAssertEqual(lighting.data?.redShown, true)
        XCTAssertEqual(lighting.data?.restored, true)
        let effects = spy.sent.filter { $0.report.commandClass == 0x0F && $0.report.commandId == 0x02 }
        XCTAssertEqual(effects.map { $0.report.arguments[1] }, [Razer.backlightLed, Razer.backlightLed],
                       "red and the restore both name the keyboard's LED, not the mouse's")
        XCTAssertEqual(effects.first.map { Array($0.report.arguments[6...8]) }, [255, 0, 0])
        XCTAssertEqual(effects.map(\.id), [0x1F, 0x1F])
        XCTAssertEqual(try DeviceProbe.brightnessSweep(spy.base)[3].result.get().value, 200, "brightness back exactly")

        DeviceTestSteps.answered(dimmed: true, turnedRed: true, &lighting)
        XCTAssertEqual(lighting.outcome, .passed)
        _ = identify
    }

    func testWithNothingToPutBackTheColoursAreLeftAlone() {
        let spy = keyboard(answering: 0x1F)
        let (_, lighting) = DeviceTestSteps.accessoryLighting(spy, info: ornata, restoreEffect: nil,
                                                              seconds: 0, wait: { _ in })
        XCTAssertEqual(lighting.data?.dimShown, true)
        XCTAssertEqual(lighting.data?.redShown, false)
        XCTAssertFalse(spy.sent.contains { $0.report.commandClass == 0x0F && $0.report.commandId == 0x02 })
    }

    // MARK: Report

    private func report(lighting outcome: DeviceReport.Outcome, verified: Bool = false) -> DeviceReport {
        var info = ornata
        if verified { info = RazerAccessories.info(pid: 0x022A)! }
        var report = DeviceTestSteps.accessoryReport(
            info: info, name: info.name, interfaces: [], control: nil,
            identify: .init(outcome: .passed), lighting: .init(outcome: outcome))
        report.verdict = report.currentVerdict()
        return report
    }

    func testTheVerdictCountsOnlyIdentifyAndLighting() throws {
        let verdict = try XCTUnwrap(report(lighting: .passed).verdict)
        XCTAssertEqual(verdict.kind, .newAllPassed, "battery, DPI and polling don't make it partial")
        XCTAssertEqual(verdict.passed, ["Identify", "Lighting"])
        XCTAssertEqual(verdict.skipped, [])
        XCTAssertEqual(verdict.notSupported, [])
        XCTAssertEqual(verdict.subjectPrefix(noun: "keyboard"), "New keyboard: all passed")
        XCTAssertEqual(try XCTUnwrap(report(lighting: .failed).verdict).subjectPrefix(noun: "keyboard"),
                       "New keyboard: 1 of 2 passed")
    }

    func testATestedModelConfirmsOrRegresses() {
        XCTAssertEqual(report(lighting: .passed, verified: true).verdict?.kind, .confirmed)
        XCTAssertEqual(report(lighting: .failed, verified: true).verdict?.kind, .possibleRegression)
    }

    func testTheReportSaysWhatTheAppDrivesItWith() throws {
        let r = report(lighting: .passed)
        let accessory = try XCTUnwrap(r.accessory)
        XCTAssertEqual(accessory.kind, .keyboard)
        XCTAssertFalse(accessory.verified)
        XCTAssertEqual(accessory.transactionId, 0x1F)
        XCTAssertEqual(accessory.effectLed, Razer.backlightLed)
        XCTAssertNil(r.registry, "the mouse registry has nothing to say about a keyboard")
        XCTAssertEqual(DeviceReportOutput.issueTitle(r), "New keyboard: all passed: Razer Ornata V3 (0x02A1)")
    }

    func testAnAccessoryThatWentAwayIsAPartialReportNotAFailure() {
        // Nothing was asked, so the maintainer mustn't read it as refused commands.
        var r = DeviceTestSteps.accessoryReport(info: ornata, name: ornata.name, interfaces: [], control: nil,
                                                identify: .init(outcome: .skipped), lighting: .init(outcome: .skipped))
        r.verdict = r.currentVerdict()
        XCTAssertEqual(r.verdict?.kind, .partlyTested)
        XCTAssertEqual(r.verdict?.failed, [])
    }

    func testNothingIsPutBackOverSynapse() {
        let defaults = UserDefaults(suiteName: "AccessoryTestTests.\(UUID())")!
        AccessoryController.store(AccessoryLighting(effect: .staticColor, color: RGB(r: 0, g: 255, b: 0), brightness: 50),
                                  pid: ornata.pid, defaults: defaults)
        let accessory = AccessoryController(id: .init(pid: ornata.pid, locationID: 1), info: ornata, defaults: defaults)
        XCTAssertNotNil(accessory.lightingRestoreReport(), "MacRazer's own effect goes back")
        accessory.loadPreviewState(synapse: true)
        XCTAssertFalse(accessory.canWrite)
        XCTAssertNil(accessory.lightingRestoreReport(), "Synapse has the colours: leave them alone")
    }

    func testTheFitIsKeptForAnUnchangedReport() {
        var cache = DeviceReportOutput.FitCache()
        let r = report(lighting: .passed)
        XCTAssertEqual(cache.fitted(r), DeviceReportOutput.fitted(r))
        var changed = r
        changed.comment = "different"
        XCTAssertEqual(cache.fitted(changed).comment, "different", "a new report is fitted afresh")
    }

    func testThankYouSaysWhatHappensNext() {
        let v = report(lighting: .passed).verdict!
        XCTAssertTrue(AccessoryTestModel.thankYou(v, noun: "keyboard").contains("UNTESTED tag comes off"))
    }

    // MARK: Worker fixture

    /// An accessory report as the Worker takes it, shared with its tests. Rewrite with
    /// UPDATE_WORKER_FIXTURE=1, like `full-report.json`.
    static func accessoryReport() -> DeviceReport {
        let info = RazerAccessories.info(pid: 0x0C08)!
        let ids = DeviceProbe.knownTransactionIds.map {
            DeviceReport.TransactionResult(id: $0, answered: $0 == 0x3F, groups: $0 == 0x3F ? ["ZERO"] : [])
        }
        var report = DeviceTestSteps.accessoryReport(
            info: info, name: info.name,
            interfaces: [.init(productID: info.pid, product: info.name, usagePage: 1, usage: 2,
                               maxFeatureReportSize: 90, maxInputReportSize: 8, transport: "USB")],
            control: 0,
            identify: .init(outcome: .passed, data: .init(firmware: "v1.0", standardAttempts: ids, lightingAttempts: ids,
                                                          standardId: 0x3F, lightingId: 0x3F)),
            lighting: .init(outcome: .failed, data: .init(groups: ["ZERO": 255], dimShown: true, redShown: true,
                                                         dimmed: true, turnedRed: false, restored: true)))
        // Fixed, not this machine's: the fixture must match on every Mac that runs the tests.
        report.appVersion = "0.9.0"
        report.macOSVersion = "26.6.2"
        report.credit = "@someone"
        report.verdict = report.currentVerdict()
        return report
    }

    func testTheWorkerGetsAccessoryReports() throws {
        let url = WorkerFixtures.url("accessory-report.json")
        let json = DeviceReportOutput.json(Self.accessoryReport(), forPublic: false) + "\n"
        if ProcessInfo.processInfo.environment["UPDATE_WORKER_FIXTURE"] == "1" {
            try json.write(to: url, atomically: true, encoding: .utf8)
        }
        func parsed(_ data: Data) throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }
        XCTAssertEqual(try parsed(Data(contentsOf: url)), try parsed(Data(json.utf8)), """
            The accessory report changed. Rewrite the fixture with UPDATE_WORKER_FIXTURE=1 swift test \
            --filter AccessoryTestTests, copy it to SorcRR/macrazer-worker's test/fixtures, and run its tests.
            """)
    }
}

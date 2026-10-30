// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The device test's steps and verdict. The rule the steps live by: whatever a step changes on
/// someone's mouse, it puts back before it returns, on every path. These check the mouse ends
/// where it started, not just that a restore was attempted.
final class DeviceTestTests: XCTestCase {
    private final class Counter { var n = 0 }

    private func dpiNow(_ mouse: FakeMouse) throws -> Int { Int(try DeviceProbe.readDPI(mouse).value.x) }
    private func pollNow(_ mouse: FakeMouse) throws -> Int { try DeviceProbe.readPollingRate(mouse).value }

    // MARK: Verdict

    private func verdict(_ known: Bool, _ outcomes: [DeviceReport.Outcome]) -> DeviceTestVerdict {
        DeviceTestVerdict.make(knownFullySupported: known,
                               steps: outcomes.enumerated().map { ("step\($0.offset)", $0.element) })
    }

    func testAKnownModelThatPassesEverythingIsAConfirmation() {
        let v = verdict(true, [.passed, .passed, .passed])
        XCTAssertEqual(v.kind, .confirmed)
        XCTAssertEqual(v.subjectPrefix, "Confirmation")
    }

    func testAKnownModelThatFailsAnythingIsAPossibleRegression() {
        // Even with a step skipped too: a failure on a supported model is the news.
        XCTAssertEqual(verdict(true, [.passed, .failed, .skipped]).kind, .possibleRegression)
    }

    func testANewModelReportsHowManyPassed() {
        let v = verdict(false, [.passed, .failed, .passed, .notSupported])
        XCTAssertEqual(v.kind, .newPartlyPassed)
        XCTAssertEqual(v.subjectPrefix, "New mouse: 2 of 3 passed", "not-supported is neither a pass nor a failure")
        XCTAssertEqual(verdict(false, [.passed, .notSupported]).kind, .newAllPassed)
    }

    func testASkippedStepIsNeverAConfirmation() {
        // A confirmation goes into the README; it has to mean every check ran.
        XCTAssertEqual(verdict(true, [.passed, .skipped]).kind, .partlyTested)
        XCTAssertEqual(verdict(false, [.passed, .skipped]).kind, .partlyTested)
    }

    // MARK: Identify

    func testIdentifyFailsAKnownModelThatNoLongerAnswersToItsId() {
        // The receiver answers, just not to the id on record: exactly the regression a
        // confirmation exists to catch.
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x00: [0x3F]]
        let info = RazerDevices.info(pid: 0x00DB)
        let (record, _) = DeviceTestSteps.identify(mouse, registry: info)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.data?.standardId, 0x3F, "still finds the id that works")
    }

    func testIdentifyReadsTheFirmwareWithTheIdItFound() {
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x00: [0x08]]
        mouse.answers(RazerCommands.getFirmwareVersion()) { $0[0] = 2; $0[1] = 1 }
        let (record, _) = DeviceTestSteps.identify(mouse, registry: nil)
        XCTAssertEqual(record.outcome, .passed)
        XCTAssertEqual(record.data?.firmware, "v2.1")
        XCTAssertEqual(record.data?.standardAttempts.map(\.answered), [false, false, false, true, false])
        XCTAssertFalse(record.exchanges.isEmpty, "the evidence travels with the step")
    }

    func testIdentifyFallsBackToADPIReadWhenNoIdAnswersTheFirmwareRead() {
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x00: [0x3F], 0x04: [0x3F]]
        mouse.refuse = { $0.commandClass == 0x00 }
        let (record, _) = DeviceTestSteps.identify(mouse, registry: nil)
        XCTAssertEqual(record.outcome, .passed, "the DPI read got a real answer")
        XCTAssertEqual(record.data?.standardId, 0x3F)
        XCTAssertEqual(record.data?.dpiAttempts?.map(\.answered), [false, true, false, false, false])
        XCTAssertNil(record.data?.firmware)
    }

    func testIdentifySkipsTheDPIReadWhenFirmwareAnswered() {
        let mouse = FakeMouse()
        let (record, _) = DeviceTestSteps.identify(mouse, registry: nil)
        XCTAssertNil(record.data?.dpiAttempts)
        XCTAssertFalse(record.exchanges.contains { $0.commandClass == 0x04 })
    }

    func testIdentifyFailsWhenOnlyRefusalsCameBack() {
        // The id is known, but nothing was read with it.
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x00: [0x3F], 0x04: [0x3F]]
        mouse.refuse = { $0.commandClass != 0x0F }
        let (record, _) = DeviceTestSteps.identify(mouse, registry: nil)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.data?.standardId, 0x3F)
    }

    func testIdentifyFailsAKnownModelWhoseLightingIdNoLongerAnswers() {
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x0F: [0x3F]]
        let (record, _) = DeviceTestSteps.identify(mouse, registry: RazerDevices.info(pid: 0x00DB))
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.data?.lightingId, 0x3F)
    }

    func testIdentifyIgnoresLightingOnAKnownModelWithoutAny() {
        // The Atheris has no lighting: nothing answering on class 0x0F is the right answer.
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x0F: []]
        let (record, _) = DeviceTestSteps.identify(mouse, registry: RazerDevices.info(pid: 0x0062))
        XCTAssertEqual(record.outcome, .passed)
        XCTAssertNil(record.data?.lightingId)
    }

    // MARK: Battery

    func testBatteryOutcomes() {
        let mouse = FakeMouse()
        mouse.answers(RazerCommands.getBatteryLevel()) { $0[1] = 200 }
        XCTAssertEqual(DeviceTestSteps.battery(mouse, expectsBattery: nil).outcome, .passed)

        let notReady = FakeMouse()
        XCTAssertEqual(DeviceTestSteps.battery(notReady, expectsBattery: nil).outcome, .failed,
                       "raw 0 is the protocol's not-ready, not an empty battery")

        let wired = FakeMouse()
        wired.refuse = { $0.commandClass == 0x07 }
        XCTAssertEqual(DeviceTestSteps.battery(wired, expectsBattery: nil).outcome, .notSupported,
                       "a new model refusing is the answer: it reports no battery")
        XCTAssertEqual(DeviceTestSteps.battery(wired, expectsBattery: true).outcome, .failed,
                       "a model on record with a battery refusing is a failure")
    }

    // MARK: DPI

    func testDPIPassesAndLeavesTheMouseWhereItWas() throws {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setDPI(x: 8000, y: 8000))
        let record = DeviceTestSteps.dpi(mouse, maxProbe: false)
        XCTAssertEqual(record.outcome, .passed)
        XCTAssertEqual(record.data?.original, 8000)
        XCTAssertEqual(record.data?.test, 7950)
        XCTAssertEqual(record.data?.readBack, 7950)
        XCTAssertEqual(record.data?.restored, true)
        XCTAssertEqual(try dpiNow(mouse), 8000)
    }

    func testDPIRestoresEvenWhenTheReadBackFails() throws {
        // The test value is written, then the read-back errors. The user's DPI still goes back.
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setDPI(x: 1600, y: 1600))
        let reads = Counter()
        mouse.refuse = { r in
            guard r.commandClass == 0x04, r.commandId == 0x85 else { return false }
            reads.n += 1
            return reads.n == 2 // the original read succeeds; the test's read-back doesn't
        }
        let record = DeviceTestSteps.dpi(mouse, maxProbe: false)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.data?.restored, true)
        mouse.refuse = { _ in false }
        XCTAssertEqual(try dpiNow(mouse), 1600)
    }

    func testAClampingMouseFailsAndIsStillRestored() throws {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setDPI(x: 800, y: 800))
        mouse.clamp = { w in
            guard w.commandClass == 0x04, w.commandId == 0x05 else { return w }
            let x = (Int(w.arguments[1]) << 8) | Int(w.arguments[2])
            return x == 750 ? RazerCommands.setDPI(x: 700, y: 700) : w
        }
        let record = DeviceTestSteps.dpi(mouse, maxProbe: false)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.data?.readBack, 700)
        XCTAssertEqual(try dpiNow(mouse), 800)
    }

    func testTheMaxProbeRecordsWhatTheMouseKeptAndRestores() throws {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setDPI(x: 3200, y: 3200))
        mouse.clamp = { w in
            guard w.commandClass == 0x04, w.commandId == 0x05 else { return w }
            let x = (Int(w.arguments[1]) << 8) | Int(w.arguments[2])
            return x > 30000 ? RazerCommands.setDPI(x: 30000, y: 30000) : w
        }
        let record = DeviceTestSteps.dpi(mouse, maxProbe: true)
        XCTAssertEqual(record.data?.maxProbe, 30000)
        XCTAssertEqual(record.outcome, .passed)
        XCTAssertEqual(try dpiNow(mouse), 3200)
    }

    func testAMaxProbeThatGetsNoAnswerRecordsNothing() throws {
        // 0 would read as the mouse's real ceiling.
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setDPI(x: 3200, y: 3200))
        mouse.refuse = { $0.commandClass == 0x04 && $0.commandId == 0x05 && $0.arguments[1] == UInt8(45000 >> 8) }
        let record = DeviceTestSteps.dpi(mouse, maxProbe: true)
        XCTAssertNil(record.data?.maxProbe)
        XCTAssertEqual(record.outcome, .passed)
        XCTAssertEqual(try dpiNow(mouse), 3200)
    }

    // MARK: Polling

    func testPollingPassesAndLeavesTheMouseWhereItWas() throws {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setPollingRate(1000))
        let record = DeviceTestSteps.polling(mouse)
        XCTAssertEqual(record.outcome, .passed)
        XCTAssertEqual(record.data?.test, 500)
        XCTAssertEqual(try pollNow(mouse), 1000)
    }

    func testAnUnnamedPollingRateIsNeverWritten() {
        // There'd be no way to write it back, so the step doesn't change it at all.
        let mouse = FakeMouse()
        var odd = RazerCommands.setPollingRate(1000)
        odd.arguments[0] = 0x04
        mouse.holds(odd)
        let record = DeviceTestSteps.polling(mouse)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertFalse(mouse.calls.contains(.retried(0x00, 0x05, attempts: 3)), "no polling write at all")
    }

    // MARK: Lighting

    private func sweep(_ mouse: FakeMouse) -> [DeviceProbe.LEDAnswer] { DeviceProbe.brightnessSweep(mouse) }

    /// A mouse lit only at LOGO, at 3% (raw 8), the way the development mouse sits.
    private func logoOnlyMouse() -> FakeMouse {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setBrightness(8, led: Razer.logoLed))
        mouse.refuse = { $0.commandClass == 0x0F && $0.commandId == 0x84 && $0.arguments[1] != Razer.logoLed }
        return mouse
    }

    private func logoBrightness(_ mouse: FakeMouse) throws -> UInt8 {
        try DeviceProbe.brightnessSweep(mouse)[0].result.get().value
    }

    func testDimOnlyLightingPutsTheExactBrightnessBack() throws {
        // How the CLI runs it: no app lighting setting to return to, so no colour change.
        let mouse = logoOnlyMouse()
        var waits: [Double] = []
        var record = DeviceTestSteps.lighting(mouse, sweep: sweep(mouse), restoreEffect: nil,
                                              seconds: 2, wait: { waits.append($0) })
        XCTAssertEqual(waits, [2])
        XCTAssertEqual(record.data?.groups, ["LOGO": 8])
        XCTAssertEqual(record.data?.dimShown, true)
        XCTAssertEqual(record.data?.redShown, false)
        XCTAssertEqual(record.data?.restored, true)
        XCTAssertEqual(try logoBrightness(mouse), 8, "back to 3%, exactly")
        XCTAssertFalse(mouse.calls.contains(.retried(0x0F, 0x02, attempts: 3)), "no effect was sent")

        DeviceTestSteps.answered(dimmed: true, turnedRed: nil, &record)
        XCTAssertEqual(record.outcome, .passed, "the colour question doesn't apply")
    }

    func testDimAndColourBothRunAndBothGoBack() throws {
        let mouse = logoOnlyMouse()
        let appSetting = RazerCommands.setStatic(rgb: RGB(r: 0x44, g: 0xD6, b: 0x2C))
        var waits: [Double] = []
        var record = DeviceTestSteps.lighting(mouse, sweep: sweep(mouse), restoreEffect: appSetting,
                                              seconds: 3, wait: { waits.append($0) })
        XCTAssertEqual(waits, [3, 3], "dark, then red, each long enough to notice")
        XCTAssertEqual(record.data?.redShown, true)
        XCTAssertEqual(record.data?.restored, true)
        XCTAssertEqual(try logoBrightness(mouse), 8, "not left at full after the red")
        XCTAssertEqual(record.outcome, .skipped, "undecided until the person answers")

        DeviceTestSteps.answered(dimmed: true, turnedRed: true, &record)
        XCTAssertEqual(record.outcome, .passed)
        DeviceTestSteps.answered(dimmed: true, turnedRed: false, &record)
        XCTAssertEqual(record.outcome, .failed, "brightness works but colours don't: that's a failure to report")
        DeviceTestSteps.answered(dimmed: nil, turnedRed: true, &record)
        XCTAssertEqual(record.outcome, .skipped)
    }

    func testAMouseWithNoLightingIsNotTouched() {
        let mouse = FakeMouse()
        mouse.refuse = { $0.commandClass == 0x0F }
        let s = sweep(mouse)
        let before = mouse.calls.count
        let record = DeviceTestSteps.lighting(mouse, sweep: s, restoreEffect: RazerCommands.setNone(),
                                              seconds: 3, wait: { _ in XCTFail("nothing to show") })
        XCTAssertEqual(record.outcome, .notSupported)
        XCTAssertEqual(mouse.calls.count, before, "no writes at all")
    }

    func testAYesDoesNotPassLightingThatWasNotPutBack() {
        let mouse = logoOnlyMouse()
        let s = sweep(mouse)
        // Brightness writes land as something else, so the restore can't confirm.
        mouse.clamp = { w in w.commandClass == 0x0F && w.commandId == 0x04 ? RazerCommands.setBrightness(1, led: w.arguments[1]) : w }
        var record = DeviceTestSteps.lighting(mouse, sweep: s, restoreEffect: nil, seconds: 0, wait: { _ in })
        XCTAssertEqual(record.data?.restored, false)
        DeviceTestSteps.answered(dimmed: true, turnedRed: nil, &record)
        XCTAssertEqual(record.outcome, .failed)
    }

    // MARK: Capabilities

    /// The rule that lets this run on anyone's mouse: every extra command is a read.
    func testEveryCapabilityReadIsAGet() {
        for (name, report) in DeviceTestSteps.capabilityReads {
            XCTAssertNotEqual(report.commandId & 0x80, 0, "\(name) is not a get")
        }
    }

    func testCapabilitiesSortEachAnswer() {
        /// Answers by command id: 0xC0 timeout, 0x83 not supported, 0x82 failed, the rest answer.
        final class Scripted: DeviceProbeChannel {
            func send(_ report: RazerReport) throws -> RazerReport { try sendWithRetry(report, attempts: 1) }
            func sendWithRetry(_ report: RazerReport, attempts: Int) throws -> RazerReport {
                switch report.commandId {
                case 0xC0: throw HIDDevice.HIDError.timeout
                case 0x83: throw HIDDevice.HIDError.notSupported
                case 0x82 where report.commandClass == 0x07: throw HIDDevice.HIDError.commandFailed
                default:
                    var reply = report
                    reply.arguments[2] = 0x2A
                    return reply
                }
            }
        }
        let reads = DeviceTestSteps.readCapabilities(Scripted()).reads
        XCTAssertEqual(reads.count, DeviceTestSteps.capabilityReads.count)
        func answer(_ name: String) -> DeviceReport.CapabilityAnswer? { reads.first { $0.name == name }?.answer }
        XCTAssertEqual(answer("pollingRate2"), .noAnswer)
        XCTAssertEqual(answer("idleTime"), .notSupported)
        XCTAssertEqual(answer("lowBatteryThreshold"), .failed)
        XCTAssertEqual(answer("profileSlots"), .answered)
        let underglow = try? XCTUnwrap(reads.first { $0.led == 0x0A })
        XCTAssertEqual(underglow?.answer, .answered)
        XCTAssertEqual(underglow?.response?.count, DeviceTestSteps.capabilityResponseBytes)
        XCTAssertEqual(underglow?.response?[2], 0x2A)
        XCTAssertNil(reads.first { $0.name == "idleTime" }?.response, "only an answer keeps bytes")
    }

    /// No id answered Identify: the reads are skipped rather than left to time out.
    func testCapabilitiesNeedAnIdThatAnswered() {
        let mouse = FakeMouse()
        let none = DeviceReport.StepRecord<DeviceReport.IdentifyData>(outcome: .failed, data: .init(
            standardAttempts: [], lightingAttempts: [], standardId: nil, lightingId: nil))
        XCTAssertNil(DeviceTestSteps.capabilities(mouse, identify: none, registry: nil))
        XCTAssertTrue(mouse.calls.isEmpty)
        var found = none
        found.data?.standardId = 0x1F
        XCTAssertEqual(DeviceTestSteps.capabilities(mouse, identify: found, registry: nil)?.reads.count,
                       DeviceTestSteps.capabilityReads.count)
        XCTAssertTrue(mouse.calls.allSatisfy { if case .retried(_, _, attempts: 1) = $0 { return true }; return false },
                      "one attempt per read")
    }

    /// Answers the button table reads from `table`, refuses the rest, and can replay the
    /// previous reply or stop answering from some id on.
    private final class ButtonTableMouse: DeviceProbeChannel {
        var table: [UInt8: [UInt8]] = [:]
        var staleIds: Set<UInt8> = []
        var silentFrom: UInt8 = .max
        private(set) var asked: [UInt8] = []
        private var last: RazerReport?
        func send(_ report: RazerReport) throws -> RazerReport { try sendWithRetry(report, attempts: 1) }
        func sendWithRetry(_ report: RazerReport, attempts: Int) throws -> RazerReport {
            let id = report.arguments[1]
            asked.append(id)
            if id >= silentFrom { throw HIDDevice.HIDError.timeout }
            if staleIds.contains(id), let last { return last }
            guard let block = table[id] else { throw HIDDevice.HIDError.commandFailed }
            var reply = report
            reply.arguments.replaceSubrange(3..<10, with: block)
            last = reply
            return reply
        }
    }

    func testTheButtonTableKeepsTheEntriesThatAnswer() {
        let mouse = ButtonTableMouse()
        mouse.table = [0x02: [1, 1, 2, 0, 0, 0, 0], 0x60: [6, 1, 6, 0, 0, 0, 0], 0x80: [0, 1, 0, 0, 0, 0, 0],
                       0x30: [0, 0, 0, 0, 0, 0, 0], 0x61: [1, 1, 5, 0, 0, 0, 0]]
        mouse.staleIds = [0x61]
        let entries = DeviceTestSteps.readButtonTable(mouse)
        XCTAssertEqual(entries.map(\.id), [0x02, 0x60, 0x80],
                       "0x30 is all zeros, and 0x61 got 0x60's reply back")
        XCTAssertEqual(entries.last?.block, [0, 1, 0, 0, 0, 0, 0], "Disabled is still an entry")
        XCTAssertEqual(mouse.asked, Array(DeviceTestSteps.buttonTableIds), "a refusal doesn't stop the sweep")
    }

    /// The probe reads' answers count, so their ids aren't asked twice.
    func testTheButtonTableUsesTheProbeAnswers() {
        let mouse = ButtonTableMouse()
        mouse.table = [0x02: [1, 1, 2, 0, 0, 0, 0]]
        var probe = DeviceTestSteps.buttonFunctionRead(0x04).arguments
        probe.replaceSubrange(3..<10, with: [1, 1, 4, 0, 0, 0, 0])
        let entries = DeviceTestSteps.readButtonTable(mouse, answered: [Array(probe.prefix(DeviceTestSteps.capabilityResponseBytes))])
        XCTAssertEqual(entries.map(\.id), [0x02, 0x04])
        XCTAssertFalse(mouse.asked.contains(0x04))
    }

    func testTheButtonTableStopsWhenTheMouseStopsAnswering() {
        let mouse = ButtonTableMouse()
        mouse.table = [0x02: [1, 1, 2, 0, 0, 0, 0]]
        mouse.silentFrom = 0x10
        XCTAssertEqual(DeviceTestSteps.readButtonTable(mouse).map(\.id), [0x02])
        XCTAssertEqual(mouse.asked.last, 0x13, "four timeouts in a row, then no more")
    }

    /// The table is swept only on a mouse that answered one of the two probe reads.
    func testTheButtonTableNeedsAButtonFunctionAnswer() {
        let found = DeviceReport.StepRecord<DeviceReport.IdentifyData>(outcome: .passed, data: .init(
            standardAttempts: [], lightingAttempts: [], standardId: 0x1F, lightingId: 0x1F))
        let refusing = FakeMouse()
        refusing.refuse = { $0.commandClass == 0x02 && $0.commandId == 0x8C }
        XCTAssertNil(DeviceTestSteps.capabilities(refusing, identify: found, registry: nil)?.buttonTable)
        let answering = FakeMouse()
        answering.answers(DeviceTestSteps.buttonFunctionRead(0x04)) { $0[3] = 0x01; $0[4] = 0x01; $0[5] = 0x04 }
        XCTAssertEqual(DeviceTestSteps.capabilities(answering, identify: found, registry: nil)?.buttonTable?.map(\.id), [0x04],
                       "FakeMouse keys reads by command, so every id echoes 0x04's args and only 0x04 matches")
    }

    func testIdentifyTriesOtherInterfacesOnlyWhenNothingReplied() {
        let silent = FakeMouse()
        silent.acceptedIds = [0x00: [], 0x04: [], 0x0F: []]
        let other = FakeMouse()
        other.acceptedIds = [0x00: [0x1F]]
        var asked = 0
        let (record, _) = DeviceTestSteps.identify(silent, registry: nil, others: {
            asked += 1
            return DeviceTestSteps.tryInterfaces([(usagePage: 0x01, usage: 0x06, channel: other)], preferred: nil)
        })
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(record.data?.otherInterfaces?.first?.usage, 0x06)
        XCTAssertEqual(record.data?.otherInterfaces?.first?.attempts.filter(\.answered).map(\.id), [0x1F])
        XCTAssertNil(record.data?.standardId, "the steps still run on the interface MacRazer picked")

        let answering = FakeMouse()
        _ = DeviceTestSteps.identify(answering, registry: nil, others: { asked += 1; return [] })
        XCTAssertEqual(asked, 1, "not asked when an id answered")
    }

    func testTheSummaryListsWhatElseTheMouseAnswers() {
        var report = DeviceReportSenderTests.fullReport()
        report.capabilities = .init(reads: [
            .init(name: "pollingRate2", commandClass: 0x00, commandId: 0xC0, answer: .answered, response: [0, 8]),
            .init(name: "buttonFunction", commandClass: 0x02, commandId: 0x8C, answer: .answered),
            .init(name: "buttonFunction", commandClass: 0x02, commandId: 0x8C, answer: .answered),
            .init(name: "idleTime", commandClass: 0x07, commandId: 0x83, answer: .notSupported),
            .init(name: "zoneEffect", commandClass: 0x0F, commandId: 0x82, led: 0x04, answer: .answered),
            .init(name: "zoneEffect", commandClass: 0x0F, commandId: 0x82, led: 0x05, answer: .failed),
            .init(name: "zoneEffect", commandClass: 0x0F, commandId: 0x82, led: 0x0A, answer: .answered),
        ])
        XCTAssertTrue(DeviceReportOutput.summary(report).contains(
            "Also answers: pollingRate2, buttonFunction, lighting zones 0x04 0x0A"))
        report.capabilities?.buttonTable = [.init(id: 0x02, block: [1, 1, 2, 0, 0, 0, 0])]
        XCTAssertTrue(DeviceReportOutput.summary(report).contains("lighting zones 0x04 0x0A, button table (1 entry)"))
        report.capabilities = .init(reads: [])
        XCTAssertTrue(DeviceReportOutput.summary(report).contains("Also answers: none of the extra reads"))
        report.capabilities = nil
        XCTAssertFalse(DeviceReportOutput.summary(report).contains("Also answers"))
    }

    /// The numbering is read as the mouse answers it, so 0-based and 1-based mice both show.
    func testTheDPIStepRecordsTheStageNumbering() {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setDPI(x: 1600, y: 1600))
        mouse.holds(RazerCommands.setDPIStages([400, 800, 1600], activeStage: 2))
        let data = DeviceTestSteps.dpi(mouse, maxProbe: false).data
        XCTAssertEqual(data?.firstStageNumber, 0)
        XCTAssertEqual(data?.activeStageByte, 2)
    }

    // MARK: Report

    func testTheReportNeverCarriesASerialNumberAndStaysSmall() throws {
        // Built from a full run against the fake, then encoded the way it will be sent.
        let mouse = FakeMouse()
        mouse.answers(RazerCommands.getBatteryLevel()) { $0[1] = 150 }
        mouse.holds(RazerCommands.setDPI(x: 1600, y: 1600))
        mouse.holds(RazerCommands.setPollingRate(1000))
        mouse.holds(RazerCommands.setBrightness(80, led: Razer.logoLed))
        let (identify, lightSweep) = DeviceTestSteps.identify(mouse, registry: nil)
        let report = DeviceReport(
            appVersion: "0.5.0", macOSVersion: "26.6.2",
            device: .init(vendorID: 0x1532, productID: 0x00DB, name: "Razer Cobra HyperSpeed",
                          connection: .dongle, interfaces: [], controlInterface: nil),
            registry: nil, identify: identify,
            battery: DeviceTestSteps.battery(mouse, expectsBattery: nil),
            dpi: DeviceTestSteps.dpi(mouse, maxProbe: true),
            polling: DeviceTestSteps.polling(mouse),
            lighting: DeviceTestSteps.lighting(mouse, sweep: lightSweep, restoreEffect: RazerCommands.setNone(),
                                               seconds: 0, wait: { _ in }),
            buttons: .init(outcome: .passed, data: .init(seen: ["09:04", "09:05"])),
            capabilities: DeviceTestSteps.readCapabilities(mouse),
            verdict: nil, comment: String(repeating: "x", count: 2000), credit: "someone", replyEmail: nil)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("serial"))
        XCTAssertLessThan(json.utf8.count, 16 * 1024, "the Worker's cap, with room to spare")
    }
}

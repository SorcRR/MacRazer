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
            verdict: nil, comment: String(repeating: "x", count: 2000), credit: "someone", replyEmail: nil)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("serial"))
        XCTAssertLessThan(json.utf8.count, 16 * 1024, "the Worker's cap, with room to spare")
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// `DeviceProbe` is what the CLI probes run on, and what the in-app device test will run on.
/// These drive it with a fake mouse that records every command and answers the way the real
/// protocol does, so the probes' commands, order and decoding are pinned without hardware.
final class DeviceProbeTests: XCTestCase {
    /// A mouse that remembers the last value written to each setting and answers reads with
    /// it, since the protocol's set and get layouts mirror each other. `refuse` makes chosen
    /// commands answer FAILURE, and `clamp` lets a write land as something else.
    private final class FakeMouse: DeviceProbeChannel {
        enum Call: Equatable {
            case once(UInt8, UInt8)
            case retried(UInt8, UInt8, attempts: Int)
        }

        let productID = 0x00DB
        private(set) var calls: [Call] = []
        var refuse: (RazerReport) -> Bool = { _ in false }
        var clamp: (RazerReport) -> RazerReport = { $0 }
        /// Last written arguments, keyed by command class and the read's command id.
        private var stored: [UInt16: [UInt8]] = [:]

        func send(_ report: RazerReport) throws -> RazerReport {
            calls.append(.once(report.commandClass, report.commandId))
            return try answer(report)
        }

        func sendWithRetry(_ report: RazerReport, attempts: Int) throws -> RazerReport {
            calls.append(.retried(report.commandClass, report.commandId, attempts: attempts))
            return try answer(report)
        }

        /// The mouse already holds this setting, as if `write` had been sent earlier.
        func holds(_ write: RazerReport) {
            stored[key(write.commandClass, write.commandId | 0x80)] = write.arguments
        }

        /// For values nothing writes, like the battery level: answer `read` with these bytes.
        func answers(_ read: RazerReport, _ edit: (inout [UInt8]) -> Void) {
            var arguments = read.arguments
            edit(&arguments)
            stored[key(read.commandClass, read.commandId)] = arguments
        }

        private func key(_ cls: UInt8, _ id: UInt8) -> UInt16 { UInt16(cls) << 8 | UInt16(id) }

        private func answer(_ report: RazerReport) throws -> RazerReport {
            if refuse(report) { throw HIDDevice.HIDError.commandFailed }
            var reply = report
            reply.status = RazerStatus.successful.rawValue
            if report.commandId & 0x80 == 0 {
                // A write: remember it under the matching read's id (set 0x05 → get 0x85).
                let landed = clamp(report)
                stored[key(report.commandClass, report.commandId | 0x80)] = landed.arguments
            } else if let previous = stored[key(report.commandClass, report.commandId)] {
                reply.arguments = previous
            }
            return reply
        }
    }

    func testBatteryReadsTheLevelByte() throws {
        let mouse = FakeMouse()
        mouse.answers(RazerCommands.getBatteryLevel()) { $0[1] = 217 }
        let battery = try DeviceProbe.battery(mouse)
        XCTAssertEqual(battery.value, 217, "the level is args[1]; args[0] is the var-store echo")
        XCTAssertEqual(battery.response.status, RazerStatus.successful.rawValue)
        XCTAssertEqual(mouse.calls, [.retried(0x07, 0x80, attempts: DeviceProbe.attempts)])
    }

    func testADPIWriteIsConfirmedByTheReadBackNotTheAcknowledgement() throws {
        let mouse = FakeMouse()
        let check = try DeviceProbe.writeDPI(mouse, .init(x: 1600, y: 1600))
        XCTAssertTrue(check.confirmed)
        XCTAssertEqual(check.readBack.value, .init(x: 1600, y: 1600))
        XCTAssertEqual(mouse.calls, [.retried(0x04, 0x05, attempts: 3), .retried(0x04, 0x85, attempts: 3)],
                       "write first, then read back")
    }

    func testAMouseThatClampsIsNotConfirmed() throws {
        // A request above the model's ceiling is acknowledged and then stored as the ceiling.
        // Only the read-back shows it, and that difference is how the device test will find
        // a model's real maximum.
        let mouse = FakeMouse()
        mouse.clamp = { write in
            guard write.commandId == 0x05, write.commandClass == 0x04 else { return write }
            return RazerCommands.setDPI(x: 20000, y: 20000)
        }
        let check = try DeviceProbe.writeDPI(mouse, .init(x: 26000, y: 26000))
        XCTAssertEqual(check.setResponse.status, RazerStatus.successful.rawValue)
        XCTAssertFalse(check.confirmed)
        XCTAssertEqual(check.readBack.value, .init(x: 20000, y: 20000))
    }

    func testPollingRateWriteReadsBack() throws {
        let mouse = FakeMouse()
        let check = try DeviceProbe.writePollingRate(mouse, hz: 500)
        XCTAssertTrue(check.confirmed)
        XCTAssertEqual(check.readBack.value, 500)
        XCTAssertEqual(mouse.calls, [.retried(0x00, 0x05, attempts: 3), .retried(0x00, 0x85, attempts: 3)])
    }

    func testAnUnnamedPollingRateReadsAsZero() throws {
        let mouse = FakeMouse()
        var odd = RazerCommands.setPollingRate(1000)
        odd.arguments[0] = 0x04 // not in the protocol table, as a faster model might answer
        mouse.holds(odd)
        XCTAssertEqual(try DeviceProbe.readPollingRate(mouse).value, 0)
    }

    func testStageWriteReturnsTheTableReadBack() throws {
        let mouse = FakeMouse()
        let write = try DeviceProbe.writeStages(mouse, stages: [400, 800, 1600], activeStage: 1)
        XCTAssertEqual(write.readBack.value.stages, [400, 800, 1600])
        XCTAssertEqual(write.readBack.value.activeByte, 1)
        XCTAssertEqual(mouse.calls, [.retried(0x04, 0x06, attempts: 3), .retried(0x04, 0x86, attempts: 3)])
    }

    func testBrightnessSweepAsksEveryGroupOnceAndKeepsGoingPastRefusals() {
        // The Basilisk V3 X shape: only the scroll wheel answers.
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setBrightness(0x80, led: Razer.scrollLed))
        mouse.refuse = { $0.commandClass == 0x0F && $0.arguments[1] != Razer.scrollLed }
        let answers = DeviceProbe.brightnessSweep(mouse)

        XCTAssertEqual(answers.map(\.name), ["LOGO", "SCROLL", "ZERO", "BACKLIGHT"])
        XCTAssertEqual(answers.map(\.led), [Razer.logoLed, Razer.scrollLed, Razer.zeroLed, Razer.backlightLed])
        XCTAssertEqual(try answers[1].result.get().value, 0x80)
        for refused in [answers[0], answers[2], answers[3]] {
            XCTAssertThrowsError(try refused.result.get(), refused.name)
        }
        // A refusal is deterministic per model and LED, so the sweep never retries it.
        XCTAssertEqual(mouse.calls, Array(repeating: .once(0x0F, 0x84), count: 4))
    }

    func testABrightnessWriteThatIsRefusedThrows() {
        // Outside the sweep a refusal is a real failure, not a group that doesn't answer.
        let mouse = FakeMouse()
        mouse.refuse = { $0.commandClass == 0x0F }
        XCTAssertThrowsError(try DeviceProbe.writeBrightness(mouse, raw: 8, led: Razer.logoLed))
    }

    func testBrightnessWriteReadsBackTheRawValue() throws {
        let mouse = FakeMouse()
        let check = try DeviceProbe.writeBrightness(mouse, raw: 8, led: Razer.logoLed)
        XCTAssertTrue(check.confirmed)
        XCTAssertEqual(mouse.calls, [.retried(0x0F, 0x04, attempts: 3), .retried(0x0F, 0x84, attempts: 3)])
    }

    func testLightingIsSentWithTheUsualRetries() throws {
        let mouse = FakeMouse()
        let red = RazerCommands.setStatic(rgb: RGB(r: 255, g: 0, b: 0))
        let response = try DeviceProbe.applyLighting(mouse, red)
        XCTAssertEqual(response.status, RazerStatus.successful.rawValue)
        XCTAssertEqual(mouse.calls, [.retried(red.commandClass, red.commandId, attempts: 3)])
    }

    func testErrorsReachTheCaller() {
        // The CLI prints them and the device test records them; a probe swallowing one would
        // turn "the mouse refused" into "the mouse said zero".
        let mouse = FakeMouse()
        mouse.refuse = { _ in true }
        XCTAssertThrowsError(try DeviceProbe.battery(mouse))
        XCTAssertThrowsError(try DeviceProbe.readDPI(mouse))
        XCTAssertThrowsError(try DeviceProbe.readPollingRate(mouse))
        XCTAssertThrowsError(try DeviceProbe.readStages(mouse))
    }
}

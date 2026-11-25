// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The Basilisk V4 HyperSpeed: lighting on ZERO_LED with brightness read on 0x0A, and the
/// V4 Pro's button table without the two entries this mouse keeps elsewhere.
final class BasiliskV4HyperSpeedTests: XCTestCase {
    private let dongle = 0x00EA, cable = 0x00EB

    func testLightingIsOfferedOnBothUSBLinks() {
        for pid in [dongle, cable] {
            XCTAssertTrue(RazerDevices.hasLighting(pid: pid), String(pid, radix: 16))
            XCTAssertTrue(RazerDevices.hasBrightness(pid: pid), String(pid, radix: 16))
        }
    }

    func testBrightnessIsWrittenOnZeroLedAndReadOn0x0A() {
        for pid in [dongle, cable] {
            XCTAssertEqual(RazerDevices.brightnessLeds(pid: pid), [Razer.zeroLed], String(pid, radix: 16))
            XCTAssertEqual(RazerDevices.brightnessReadLed(pid: pid), 0x0A, String(pid, radix: 16))
        }
    }

    func testOtherMiceReadBrightnessWhereTheyWriteIt() {
        // V4 Pro (logo), V3 X HyperSpeed (scroll wheel), an unknown mouse (logo fallback).
        for pid in [0x00E3, 0x00B9, 0xFFFF] {
            XCTAssertEqual(RazerDevices.brightnessReadLed(pid: pid), RazerDevices.brightnessLed(pid: pid), String(pid, radix: 16))
        }
    }

    func testOnlyThisMouseHasASplitBrightnessRead() throws {
        for pid in [dongle, cable] {
            let split = try XCTUnwrap(RazerDevices.brightnessSplitRead(pid: pid), String(pid, radix: 16))
            XCTAssertEqual(split.led, Razer.zeroLed)
            XCTAssertEqual(split.readLed, 0x0A)
        }
        XCTAssertFalse(RazerDevices.known.contains { $0.pid != dongle && $0.pid != cable
            && RazerDevices.brightnessSplitRead(pid: $0.pid) != nil })
        XCTAssertNil(RazerDevices.brightnessSplitRead(pid: 0xFFFF))
    }

    /// A mouse that keeps brightness written on ZERO_LED and answers a read only on 0x0A.
    private func splitReadMouse(raw: UInt8) -> FakeMouse {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setBrightness(raw, led: 0x0A))
        mouse.refuse = { r in
            r.commandClass == 0x0F && (r.commandId == 0x84 ? r.arguments[1] != 0x0A : r.commandId == 0x04 && r.arguments[1] != Razer.zeroLed)
        }
        mouse.clamp = { w in
            w.commandClass == 0x0F && w.commandId == 0x04 ? RazerCommands.setBrightness(w.arguments[2], led: 0x0A) : w
        }
        return mouse
    }

    func testDeviceTestDimsAndRestoresLightingThroughTheReadLed() throws {
        let mouse = splitReadMouse(raw: 77)
        let sweep = DeviceProbe.brightnessSweep(mouse)
        XCTAssertFalse(sweep.contains { (try? $0.result.get()) != nil }, "the sweep finds nothing")
        var waits: [Double] = []
        var record = DeviceTestSteps.lighting(mouse, sweep: sweep, splitRead: RazerDevices.brightnessSplitRead(pid: dongle),
                                              restoreEffect: nil, seconds: 2, wait: { waits.append($0) })
        XCTAssertEqual(waits, [2])
        XCTAssertEqual(record.data?.groups, ["ZERO": 77], "a name the Worker takes")
        XCTAssertEqual(record.data?.dimShown, true)
        XCTAssertEqual(record.data?.restored, true)
        XCTAssertEqual(try mouse.send(RazerCommands.getBrightness(led: 0x0A)).arguments[2], 77)
        DeviceTestSteps.answered(dimmed: true, turnedRed: nil, &record)
        XCTAssertEqual(record.outcome, .passed)
    }

    /// The identify sweep never asks 0x0A, so on its own it finds no lighting id. k4ton's
    /// dongle report (#55) failed identify this way while every other step passed.
    func testIdentifyAsksTheReadLed() throws {
        let mouse = splitReadMouse(raw: 77)
        let (record, sweep) = DeviceTestSteps.identify(mouse, registry: RazerDevices.info(pid: dongle))
        XCTAssertEqual(record.outcome, .passed)
        let data = try XCTUnwrap(record.data)
        XCTAssertEqual(data.lightingId, 0x1F)
        let attempt = try XCTUnwrap(data.lightingAttempts.first { $0.id == 0x1F })
        XCTAssertTrue(attempt.answered)
        XCTAssertFalse(attempt.refused)
        XCTAssertEqual(attempt.groups, ["ZERO"])
        XCTAssertTrue(record.exchanges.contains { $0.commandClass == 0x0F && $0.commandId == 0x84 && $0.transactionId == 0x1F })
        // The sweep handed to the lighting step is untouched: it asks 0x0A itself.
        XCTAssertFalse(try XCTUnwrap(sweep).contains { (try? $0.result.get()) != nil })
    }

    /// A mouse that answers neither the sweep nor the read LED still fails identify.
    func testIdentifyStillFailsWhenTheReadLedIsSilentToo() {
        let mouse = splitReadMouse(raw: 77)
        let refuse = mouse.refuse
        mouse.refuse = { r in (r.commandClass == 0x0F && r.commandId == 0x84) || refuse(r) }
        XCTAssertEqual(DeviceTestSteps.identify(mouse, registry: RazerDevices.info(pid: dongle)).record.outcome, .failed)
    }

    /// Every split-read model's write LED has a name the Worker takes, so its lighting
    /// report isn't turned down.
    func testSplitReadGroupsAreNamesTheWorkerTakes() {
        let workerNames: Set = ["LOGO", "SCROLL", "ZERO", "BACKLIGHT", "UNDERGLOW", "RIGHT_SIDE", "LEFT_SIDE"]
        for row in RazerDevices.known {
            guard let split = RazerDevices.brightnessSplitRead(pid: row.pid) else { continue }
            XCTAssertTrue(workerNames.contains(DeviceProbe.groupName(led: split.led)), String(row.pid, radix: 16))
        }
    }

    func testWithoutTheSplitReadTheStepStillSaysNotSupported() {
        let mouse = splitReadMouse(raw: 77)
        let record = DeviceTestSteps.lighting(mouse, sweep: DeviceProbe.brightnessSweep(mouse),
                                              restoreEffect: nil, seconds: 0, wait: { _ in })
        XCTAssertEqual(record.outcome, .notSupported)
    }

    func testCableLightingWaitsForATest() {
        XCTAssertEqual(RazerDevices.unverified(pid: cable), [.lighting], "its polling passed with polling_rate2")
        XCTAssertEqual(RazerDevices.unverified(pid: dongle), [.polling, .lighting], "its 0x0A read was 0 on a lit mouse")
    }

    func testDongleTableIsTheV4ProsWithoutDpiAndWheelMode() throws {
        let hyperSpeed = try XCTUnwrap(OnboardButtons.layout(pid: dongle))
        let pro = try XCTUnwrap(OnboardButtons.layout(pid: 0x00E3))
        let left = Set([HardwareButton.dpiCycle.rawValue, HardwareButton.wheelMode.rawValue])
        XCTAssertEqual(hyperSpeed, pro.filter { !left.contains($0.button) })
        XCTAssertEqual(hyperSpeed.count, 11)
        XCTAssertFalse(hyperSpeed.contains { $0.tableID == 0x60 || $0.tableID == 0x6A })
    }

    func testTheTwoSilentThumbButtonsAreRemappable() throws {
        let table = try XCTUnwrap(OnboardButtons.layout(pid: dongle))
        let trigger = try XCTUnwrap(table.first { $0.button == HardwareButton.sideTrigger.rawValue })
        let front = try XCTUnwrap(table.first { $0.button == HardwareButton.sideFront.rawValue })
        // Factory blocks as read from this mouse (SorcRR/MacRazer#135).
        XCTAssertEqual(trigger.tableID, 0x39)
        XCTAssertEqual(trigger.factory, [0x0C, 0x01, 0x39, 0, 0, 0, 0])
        XCTAssertEqual(front.tableID, 0x80)
        XCTAssertEqual(front.factory, OnboardButtons.disabledBlock)
    }

    /// 0.9.0 did this mouse's remaps in software. The first sync after the update reads
    /// factory functions from the mouse, and the remaps must survive it.
    func testRemapsFromBeforeTheTableSurviveTheFirstSync() throws {
        let table = try XCTUnwrap(OnboardButtons.layout(pid: dongle))
        let standard = Dictionary(uniqueKeysWithValues: table.map { ($0.tableID, $0.factory) })
        let shifted: [UInt8: [UInt8]?] = Dictionary(uniqueKeysWithValues: table.map { ($0.tableID, nil) })
        let old: [Int: RemapAction] = [3: ButtonRemapper.presets[0].action, 4: .mediaKey(code: 7, name: "Mute")]
        XCTAssertEqual(OnboardButtons.adopt(pid: dongle, mappings: old, standard: standard, shifted: shifted,
                                            neverWritten: { _, _ in true }), old)
    }

    func testRowOrderListsOnlyTheButtonsThisMouseHas() throws {
        let rows = try XCTUnwrap(OnboardButtons.rowOrder(pid: dongle))
        let table = try XCTUnwrap(OnboardButtons.layout(pid: dongle))
        XCTAssertEqual(Set(rows), Set(table.map(\.button)))
        XCTAssertEqual(rows.count, table.count)
        // The V4 Pro still lists all thirteen.
        XCTAssertEqual(OnboardButtons.rowOrder(pid: 0x00E3)?.count, 13)
    }

    func testCableAndBluetoothKeepNoTableUntilOneIsRead() {
        XCTAssertNil(OnboardButtons.layout(pid: cable))
        XCTAssertNil(OnboardButtons.layout(pid: 0x00EC))
    }

    // MARK: Polling (00:0E / 00:8E, openrazer/openrazer#2959)

    func testPollingReadIs008EWithVarstore() {
        let read = RazerCommands.pollingRateRead(command: .basiliskV4HyperSpeed).report
        XCTAssertEqual(read.commandClass, 0x00)
        XCTAssertEqual(read.commandId, 0x8E)
        XCTAssertEqual(read.dataSize, 0x02)
        XCTAssertEqual(read.arguments[0], 0x01)
    }

    func testPollingWriteIsOne000ECommandWithClassicCodes() {
        for (hz, code) in [(1000, UInt8(0x01)), (500, 0x02), (125, 0x08)] {
            let reports = RazerCommands.setPollingRateReports(hz, command: .basiliskV4HyperSpeed)
            XCTAssertEqual(reports.count, 1, "\(hz)")
            XCTAssertEqual(reports[0].commandClass, 0x00)
            XCTAssertEqual(reports[0].commandId, 0x0E)
            XCTAssertEqual(reports[0].dataSize, 0x02)
            XCTAssertEqual(Array(reports[0].arguments[0...1]), [0x01, code], "\(hz)")
        }
        // A rate this mouse lacks falls back to 1000 Hz.
        XCTAssertEqual(RazerCommands.setPollingRateV4HyperSpeed(250).arguments[1], 0x01)
    }

    func testPollingAnswerDecodesTheSecondArgument() {
        var resp = RazerReport(commandClass: 0x00, commandId: 0x8E, dataSize: 0x02)
        resp.arguments[0] = 0x01
        for (code, hz) in [(UInt8(0x01), 1000), (0x02, 500), (0x08, 125), (0x04, 0)] {
            resp.arguments[1] = code
            XCTAssertEqual(RazerCommands.parsePollingRateV4HyperSpeed(resp), hz, "code \(code)")
        }
    }

    func testOtherCommandsAreUnchanged() {
        XCTAssertEqual(RazerCommands.setPollingRateReports(1000, command: .classic).map(\.commandId), [0x05])
        XCTAssertEqual(RazerCommands.setPollingRateReports(1000, command: .rate2).map(\.commandId), [0x40, 0x40])
        XCTAssertEqual(RazerCommands.pollingRateRead(command: .rate2).report.commandId, 0xC0)
        XCTAssertEqual(RazerCommands.pollingRateRead(command: .classic).report.commandId, 0x85)
    }

    /// Its polling command's first argument is the slot, like the other settings commands,
    /// so each profile keeps its own rate: set and read go to the active slot.
    func testPollingFollowsTheActiveSlot() {
        let set = OnboardSlots.retarget(RazerCommands.setPollingRateV4HyperSpeed(500), to: 2)
        XCTAssertEqual(set.arguments[0], 2)
        XCTAssertEqual(set.arguments[1], 0x02, "500 Hz is kept")
        XCTAssertEqual(OnboardSlots.retarget(RazerCommands.getPollingRateV4HyperSpeed(), to: 3).arguments[0], 3)
        // Slot 1 is what it always sent.
        XCTAssertEqual(OnboardSlots.retarget(RazerCommands.setPollingRateV4HyperSpeed(500), to: 1).arguments[0], 1)
        // The other polling commands carry no slot: their first argument is the rate.
        let classic = RazerCommands.setPollingRateReports(500, command: .classic)[0]
        XCTAssertEqual(OnboardSlots.retarget(classic, to: 2).arguments, classic.arguments)
        for report in RazerCommands.setPollingRateReports(500, command: .rate2) {
            XCTAssertEqual(OnboardSlots.retarget(report, to: 2).arguments, report.arguments)
        }
    }

    /// The app's polling write goes through `DeviceProbe` on the bare link; it must still
    /// reach the active slot, set and read-back alike. It used to land on slot 1.
    func testPollingWriteThroughTheProbeReachesTheActiveSlot() throws {
        final class Recorder: DeviceProbeChannel {
            var sent: [RazerReport] = []
            func send(_ report: RazerReport) throws -> RazerReport { try sendWithRetry(report, attempts: 1) }
            func sendWithRetry(_ report: RazerReport, attempts: Int) throws -> RazerReport {
                sent.append(report)
                var reply = report
                reply.arguments[1] = 0x02 // holds 500 Hz
                return reply
            }
        }
        let link = Recorder()
        let check = try DeviceProbe.writePollingRate(SlotChannel(base: link, slot: 2), hz: 500,
                                                     command: .basiliskV4HyperSpeed)
        XCTAssertTrue(check.confirmed)
        XCTAssertEqual(link.sent.map(\.commandId), [0x0E, 0x8E])
        XCTAssertEqual(link.sent.map { $0.arguments[0] }, [2, 2])
    }

    /// A remap table handed back from before the latest slot change is dropped: it is the
    /// previous slot's, and written to the new one it put back to factory every remap
    /// MacRazer had written there (2026-11-15).
    func testOnlyARemapTableFromTheCurrentSlotIsKept() {
        XCTAssertTrue(MouseController.handedTableIsCurrent(handedEpoch: 3, slotEpoch: 3))
        XCTAssertFalse(MouseController.handedTableIsCurrent(handedEpoch: 2, slotEpoch: 3))
    }

    /// The dongle keeps its profiles in onboard slots, like the V4 Pro. Its factory slot
    /// settings haven't been read yet, so a new or reset slot only gets its button table back.
    func testDongleHasSlotsButNoFactorySettingsYet() {
        XCTAssertTrue(RazerDevices.hasOnboardSlots(pid: dongle))
        XCTAssertTrue(OnboardSlots.factorySettings(pid: dongle).isEmpty)
        XCTAssertNotNil(OnboardButtons.layout(pid: dongle))
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// Transaction-id discovery and the channels the device test runs its probes through. A wrong
/// id makes every other probe on an unknown model fail, so finding the right one, and keeping
/// the evidence of how it was found, is the first job of the test.
final class DeviceProbeSessionTests: XCTestCase {
    private let firmwareRead = RazerCommands.getFirmwareVersion()

    func testCandidatesPutTheRegistryIdFirstAndNeverRepeat() {
        XCTAssertEqual(DeviceProbe.transactionCandidates(preferred: 0x3F), [0x3F, 0x1F, 0xFF, 0x08, 0x80])
        XCTAssertEqual(DeviceProbe.transactionCandidates(preferred: 0x1F), [0x1F, 0x3F, 0xFF, 0x08, 0x80])
        XCTAssertEqual(DeviceProbe.transactionCandidates(preferred: nil), DeviceProbe.knownTransactionIds)
        XCTAssertEqual(DeviceProbe.transactionCandidates(preferred: 0x42), [0x42, 0x1F, 0x3F, 0xFF, 0x08, 0x80])
    }

    func testDiscoveryTriesEveryIdAndKeepsEachResult() {
        // The shape measured on a Cobra HyperSpeed: three ids answer, two don't. All five are
        // tried, because which ones answer is the evidence, not just the first that does.
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x00: [0x1F, 0x3F, 0x08]]
        let attempts = DeviceProbe.discoverTransactionIds(mouse, read: firmwareRead, preferred: nil)

        XCTAssertEqual(attempts.map(\.id), [0x1F, 0x3F, 0xFF, 0x08, 0x80])
        XCTAssertEqual(attempts.map(\.answered), [true, true, false, true, false])
        XCTAssertEqual(mouse.transactionIds, [0x1F, 0x3F, 0xFF, 0x08, 0x80])
        XCTAssertEqual(DeviceProbe.chosenId(attempts), 0x1F)
    }

    func testAnUnknownModelUsesTheFirstIdThatAnswers() {
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x00: [0x08, 0x3F]]
        let attempts = DeviceProbe.discoverTransactionIds(mouse, read: firmwareRead, preferred: nil)
        XCTAssertEqual(DeviceProbe.chosenId(attempts), 0x3F, "0x3F comes before 0x08 in the known order")
    }

    func testTheRegistryIdWinsWhenItAnswers() {
        // A known model whose receiver also answers to other ids keeps the one on record.
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x00: [0x1F, 0xFF]]
        let attempts = DeviceProbe.discoverTransactionIds(mouse, read: firmwareRead, preferred: 0xFF)
        XCTAssertEqual(DeviceProbe.chosenId(attempts), 0xFF)
    }

    func testAStaleStatusIsNotAnAnswer() {
        // `send` passes statuses it doesn't recognise straight through. A mouse ignoring a
        // wrong id can leave a zero status behind, and that must not pass for success.
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x00: [0x08]]
        mouse.wrongId = .staleStatus
        let attempts = DeviceProbe.discoverTransactionIds(mouse, read: firmwareRead, preferred: nil)
        XCTAssertEqual(attempts.map(\.answered), [false, false, false, true, false])
        XCTAssertEqual(DeviceProbe.chosenId(attempts), 0x08)
    }

    func testNoAnswerChoosesNothing() {
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x00: []]
        let attempts = DeviceProbe.discoverTransactionIds(mouse, read: firmwareRead, preferred: nil)
        XCTAssertNil(DeviceProbe.chosenId(attempts))
        XCTAssertEqual(attempts.count, DeviceProbe.knownTransactionIds.count)
    }

    func testARefusalMeansTheIdWasHeard() {
        // A model without the firmware command says no under its right id, and nothing at all
        // under the wrong ones. "Said no" still picks the id.
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x00: [0x3F]]
        mouse.refuse = { $0.commandClass == 0x00 }
        let attempts = DeviceProbe.discoverTransactionIds(mouse, read: firmwareRead, preferred: nil)
        XCTAssertEqual(attempts.map(\.refused), [false, true, false, false, false])
        XCTAssertFalse(attempts.contains(where: \.answered))
        XCTAssertEqual(DeviceProbe.chosenId(attempts), 0x3F)
    }

    func testAnAnswerBeatsAnEarlierRefusal() {
        var ok = firmwareRead
        ok.status = RazerStatus.successful.rawValue
        let attempts = [
            DeviceProbe.TransactionAttempt(id: 0x1F, result: .failure(HIDDevice.HIDError.notSupported)),
            DeviceProbe.TransactionAttempt(id: 0x3F, result: .failure(HIDDevice.HIDError.timeout)),
            DeviceProbe.TransactionAttempt(id: 0xFF, result: .success(ok)),
        ]
        XCTAssertEqual(attempts.map(\.refused), [true, false, false], "a timeout is not a refusal")
        XCTAssertEqual(DeviceProbe.chosenId(attempts), 0xFF)
    }

    func testLightingDiscoveryCountsAnyGroupThatAnswers() {
        // Lighting on its own id, answering only on the scroll wheel: a LOGO refusal under
        // the right id must not rule that id out.
        let mouse = FakeMouse()
        mouse.acceptedIds = [0x0F: [0xFF]]
        mouse.holds(RazerCommands.setBrightness(0x40, led: Razer.scrollLed))
        mouse.refuse = { $0.commandClass == 0x0F && $0.arguments[1] != Razer.scrollLed }
        let attempts = DeviceProbe.discoverMatrixTransactionIds(mouse, standard: 0x1F, preferred: nil)

        XCTAssertEqual(DeviceProbe.chosenId(attempts), 0xFF)
        XCTAssertEqual(attempts.first { $0.id == 0xFF }?.answeredGroups, ["SCROLL"])
        XCTAssertTrue(attempts.filter { $0.id != 0xFF }.allSatisfy { !$0.answered })
    }

    func testTheFixedChannelStampsTheLightingIdOnlyOnLighting() throws {
        let mouse = FakeMouse()
        let channel = FixedTransactionChannel(base: mouse, standard: 0x3F, matrix: 0xFF)
        _ = try DeviceProbe.battery(channel)
        _ = try channel.send(RazerCommands.getBrightness(led: Razer.logoLed))
        _ = try DeviceProbe.readDPI(channel)
        XCTAssertEqual(mouse.transactionIds, [0x3F, 0xFF, 0x3F])
    }

    func testTheFixedChannelStampsAKnownModelsOverridesAheadOfBoth() throws {
        // The Basilisk V3's DPI commands use their own id; the app's traffic honours that, so
        // the test must too, or a known model fails on a step it handles fine.
        let mouse = FakeMouse()
        let channel = FixedTransactionChannel(base: mouse, standard: 0x1F, matrix: 0x3F,
                                              overrides: [0x0485: 0xFF, 0x0F84: 0x08])
        _ = try DeviceProbe.readDPI(channel)
        _ = try DeviceProbe.battery(channel)
        _ = try channel.send(RazerCommands.getBrightness(led: Razer.logoLed))
        XCTAssertEqual(mouse.transactionIds, [0xFF, 0x1F, 0x08])
    }

    func testRecordingKeepsWhatWasAskedAndWhatCameBack() throws {
        let mouse = FakeMouse()
        mouse.answers(RazerCommands.getBatteryLevel()) { $0[1] = 200 }
        mouse.refuse = { $0.commandClass == 0x00 && $0.commandId == 0x85 }
        let recording = RecordingChannel(base: mouse)
        let channel = FixedTransactionChannel(base: recording, standard: 0x3F, matrix: 0x1F)

        _ = try DeviceProbe.battery(channel)
        XCTAssertThrowsError(try DeviceProbe.readPollingRate(channel), "errors still reach the caller")

        let battery = recording.exchanges[0]
        XCTAssertEqual(battery.commandClass, 0x07)
        XCTAssertEqual(battery.commandId, 0x80)
        XCTAssertEqual(battery.transactionId, 0x3F)
        XCTAssertEqual(battery.status, RazerStatus.successful.rawValue)
        XCTAssertEqual(battery.response.count, RecordingChannel.responseBytes)
        XCTAssertEqual(battery.response[1], 200)
        XCTAssertNil(battery.error)

        let refused = recording.exchanges[1]
        XCTAssertNil(refused.status)
        XCTAssertEqual(refused.response, [])
        XCTAssertNotNil(refused.error)
    }

    func testRecordingStopsGrowingAtItsCeiling() {
        // A device answering garbage in a loop must not grow the report without bound.
        let recording = RecordingChannel(base: FakeMouse())
        for _ in 0..<(RecordingChannel.maxExchanges + 25) {
            _ = try? DeviceProbe.battery(recording)
        }
        XCTAssertEqual(recording.exchanges.count, RecordingChannel.maxExchanges)
    }

    func testFirmwareReadsAsOpenRazerPrintsIt() throws {
        let mouse = FakeMouse()
        mouse.answers(RazerCommands.getFirmwareVersion()) { $0[0] = 1; $0[1] = 3 }
        XCTAssertEqual(try DeviceProbe.firmware(mouse).value, "v1.3")
    }
}

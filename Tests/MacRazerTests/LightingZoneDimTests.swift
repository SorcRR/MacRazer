// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The lighting test dims the underglow and side strips too, on a model whose effects go
/// there. Two 35K reports saw the red but not the dim: the underglow took the red and stayed lit.
final class LightingZoneDimTests: XCTestCase {
    private let underglow = DeviceProbe.effectZoneGroups(effectLeds: [Razer.underglowLed])

    /// LOGO answers the sweep; the underglow answers too, at `underglowAt` unless refused.
    private func mouse(underglowAt raw: UInt8?) -> FakeMouse {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setBrightness(200, led: Razer.logoLed))
        if let raw { mouse.holds(RazerCommands.setBrightness(raw, led: Razer.underglowLed)) }
        let answers: Set<UInt8> = raw == nil ? [Razer.logoLed] : [Razer.logoLed, Razer.underglowLed]
        mouse.refuse = { $0.commandClass == 0x0F && ($0.commandId & 0x7F) == 0x04 && !answers.contains($0.arguments[1]) }
        return mouse
    }

    private func brightnessWrites(_ mouse: FakeMouse, led: UInt8) -> [UInt8] {
        mouse.sent.filter { $0.commandClass == 0x0F && $0.commandId == 0x04 && $0.arguments[1] == led }.map { $0.arguments[2] }
    }

    private func run(_ mouse: FakeMouse, zoneGroups: [(name: String, led: UInt8)], colourOnly: Bool = false)
        -> DeviceReport.StepRecord<DeviceReport.LightingData> {
        let app = RazerCommands.setStatic(led: Razer.logoLed, rgb: RGB(r: 0x44, g: 0xD6, b: 0x2C))
        return DeviceTestSteps.lighting(mouse, sweep: DeviceProbe.brightnessSweep(mouse), restoreEffect: [app],
                                        zoneGroups: zoneGroups, colourOnly: colourOnly, seconds: 0, wait: { _ in })
    }

    func testAnUnderglowThatAnswersIsDimmedAndPutBack() {
        let mouse = mouse(underglowAt: 180)
        let record = run(mouse, zoneGroups: underglow)
        XCTAssertEqual(record.data?.groups, ["LOGO": 200, "UNDERGLOW": 180])
        let writes = brightnessWrites(mouse, led: Razer.underglowLed)
        XCTAssertEqual(writes.first, 0, "dimmed with the rest")
        XCTAssertEqual(writes.last, 180, "and back to its own brightness")
        XCTAssertEqual(record.data?.restored, true)
    }

    func testAnUnderglowThatRefusesChangesNothing() {
        let mouse = mouse(underglowAt: nil)
        let record = run(mouse, zoneGroups: underglow)
        XCTAssertEqual(record.data?.groups, ["LOGO": 200], "as before")
        XCTAssertEqual(brightnessWrites(mouse, led: Razer.underglowLed), [])
        XCTAssertEqual(record.data?.restored, true)
    }

    func testAZeroAnswerIsLeftAlone() {
        // The Lancehead's 0x0A echoes the read, which reads as zero: putting that back would
        // leave a lit underglow dark.
        let mouse = mouse(underglowAt: 0)
        let record = run(mouse, zoneGroups: underglow)
        XCTAssertNil(record.data?.groups["UNDERGLOW"])
        XCTAssertEqual(brightnessWrites(mouse, led: Razer.underglowLed), [])
    }

    func testAColourOnlyLightIsNotAskedForBrightness() {
        let mouse = FakeMouse()
        mouse.refuse = { $0.commandClass == 0x0F && ($0.commandId & 0x7F) == 0x04 }
        let record = run(mouse, zoneGroups: underglow, colourOnly: true)
        XCTAssertEqual(record.data?.redShown, true)
        XCTAssertFalse(record.data?.dimShown ?? true)
        let asked = mouse.sent.filter { $0.commandClass == 0x0F && $0.commandId == 0x84 }.map { $0.arguments[1] }
        XCTAssertFalse(asked.contains(Razer.underglowLed), "the red check runs alone, as before")
    }

    func testWhichZonesAModelAdds() {
        XCTAssertTrue(DeviceProbe.effectZoneGroups(effectLeds: RazerDevices.effectLeds(pid: 0x9999)).isEmpty,
                      "a model not on record gets no extra reads")
        XCTAssertEqual(DeviceProbe.effectZoneGroups(effectLeds: RazerDevices.effectLeds(pid: 0x00CC)).map(\.name),
                       ["UNDERGLOW"], "Basilisk V3 Pro 35K")
        XCTAssertEqual(DeviceProbe.effectZoneGroups(effectLeds: RazerDevices.effectLeds(pid: 0x0060)).map(\.name),
                       ["RIGHT_SIDE", "LEFT_SIDE"], "Lancehead Tournament Edition")
    }

    func testTheNamesAreTheWorkers() {
        // SorcRR/macrazer-worker's LED_GROUPS: a name it doesn't have gets the report refused.
        XCTAssertEqual((DeviceProbe.ledGroups + DeviceProbe.effectZoneGroups).map(\.name),
                       ["LOGO", "SCROLL", "ZERO", "BACKLIGHT", "UNDERGLOW", "RIGHT_SIDE", "LEFT_SIDE"])
    }
}

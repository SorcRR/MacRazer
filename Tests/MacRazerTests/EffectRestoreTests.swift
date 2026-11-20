// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The lighting test puts back the effect each zone had, read before it changed anything.
/// The answers here are the bytes real mice sent in their reports.
final class EffectRestoreTests: XCTestCase {
    /// RazerReport isn't Equatable: compare what goes on the wire.
    private func bytes(_ r: RazerReport?) -> [UInt8]? {
        r.map { [$0.commandClass, $0.commandId, $0.dataSize] + $0.arguments }
    }

    private func reply(_ args: [UInt8]) -> RazerReport {
        var r = RazerCommands.getEffect(led: 0)
        r.status = RazerStatus.successful.rawValue
        for (i, b) in args.enumerated() { r.arguments[i] = b }
        return r
    }

    // MARK: Reading an answer

    func testStaticRedFromTheLancehead() {
        // Lancehead Tournament Edition, ZERO_LED: it answers as LOGO, in static red.
        let own = RazerCommands.effectRestore(from: reply([0, 4, 1, 0, 0, 1, 255, 0, 0, 0, 0, 0]), led: Razer.zeroLed)
        XCTAssertEqual(bytes(own), bytes(RazerCommands.setStatic(led: Razer.zeroLed, rgb: RGB(r: 255, g: 0, b: 0))),
                       "put back on the led asked, not the one named")
    }

    func testSpectrumFromTheBasiliskV4Pro() {
        let own = RazerCommands.effectRestore(from: reply([0, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]), led: Razer.scrollLed)
        XCTAssertEqual(bytes(own), bytes(RazerCommands.setSpectrum(led: Razer.scrollLed)))
    }

    func testAnEchoSaysNothing() {
        // The Lancehead's 0x0A: the request back with a success status. Not "off".
        XCTAssertNil(RazerCommands.effectRestore(from: reply([1, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), led: 0x0A))
    }

    func testOtherShapes() {
        let green = RGB(r: 0, g: 255, b: 0), blue = RGB(r: 0, g: 0, b: 255)
        XCTAssertEqual(bytes(RazerCommands.effectRestore(from: reply([0, 4, 0]), led: 4)),
                       bytes(RazerCommands.setNone(led: 4)))
        XCTAssertEqual(bytes(RazerCommands.effectRestore(from: reply([0, 4, 2, 1, 0, 1, 0, 255, 0]), led: 4)),
                       bytes(RazerCommands.setBreathingSingle(led: 4, rgb: green)))
        XCTAssertEqual(bytes(RazerCommands.effectRestore(from: reply([0, 4, 2, 2, 0, 2, 0, 255, 0, 0, 0, 255]), led: 4)),
                       bytes(RazerCommands.setBreathingDual(led: 4, rgb1: green, rgb2: blue)))
        XCTAssertEqual(bytes(RazerCommands.effectRestore(from: reply([0, 4, 4, 2, 0x50]), led: 4)),
                       bytes(RazerCommands.setWave(led: 4, direction: 2, speed: 0x50)))
        XCTAssertNil(RazerCommands.effectRestore(from: reply([0, 4, 2, 3]), led: 4), "random breathing: no builder sends this shape")
        XCTAssertNil(RazerCommands.effectRestore(from: reply([0, 4, 7]), led: 4), "an effect id nothing here knows")
        var refused = reply([0, 4, 1, 0, 0, 1, 255, 0, 0])
        refused.status = 0x03
        XCTAssertNil(RazerCommands.effectRestore(from: refused, led: 4))
    }

    // MARK: The lighting step

    private func mouseLitAtLogo() -> FakeMouse {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setBrightness(200, led: Razer.logoLed))
        mouse.refuse = { $0.commandClass == 0x0F && $0.commandId == 0x84 && $0.arguments[1] != Razer.logoLed }
        return mouse
    }

    private func primeEffect(_ mouse: FakeMouse, led: UInt8, _ body: [UInt8]) {
        mouse.answers(RazerCommands.getEffect(led: led)) { args in
            args[0] = 0
            for (i, b) in body.enumerated() { args[2 + i] = b }
        }
    }

    private func lastEffect(_ mouse: FakeMouse, led: UInt8) -> RazerReport? {
        mouse.sent.last { $0.commandClass == 0x0F && $0.commandId == 0x02 && $0.arguments[1] == led }
    }

    func testTheMousesOwnColourComesBack() {
        let mouse = mouseLitAtLogo()
        primeEffect(mouse, led: Razer.logoLed, [1, 0, 0, 1, 255, 0, 0]) // red, as it was
        let app = RGB(r: 0x44, g: 0xD6, b: 0x2C)
        let leds = [Razer.logoLed, Razer.scrollLed]
        let record = DeviceTestSteps.lighting(mouse, sweep: DeviceProbe.brightnessSweep(mouse),
                                              restoreEffect: RazerCommands.effect(.staticColor, color: app, leds: leds),
                                              red: RazerCommands.effect(.staticColor, color: RGB(r: 255, g: 0, b: 0), leds: leds),
                                              seconds: 0, wait: { _ in })
        XCTAssertEqual(bytes(lastEffect(mouse, led: Razer.logoLed)), bytes(RazerCommands.setStatic(led: Razer.logoLed, rgb: RGB(r: 255, g: 0, b: 0))))
        XCTAssertEqual(bytes(lastEffect(mouse, led: Razer.scrollLed)), bytes(RazerCommands.setStatic(led: Razer.scrollLed, rgb: app)),
                       "a zone that didn't say gets the app's setting, as before")
        XCTAssertEqual(record.data?.restored, true)
    }

    func testAnEchoingMouseGetsTheAppsSetting() {
        // An unprimed FakeMouse answers the read with the request itself, like the 0x0A echo.
        let mouse = mouseLitAtLogo()
        let app = RazerCommands.setStatic(led: Razer.logoLed, rgb: RGB(r: 0x44, g: 0xD6, b: 0x2C))
        _ = DeviceTestSteps.lighting(mouse, sweep: DeviceProbe.brightnessSweep(mouse), restoreEffect: [app],
                                     seconds: 0, wait: { _ in })
        XCTAssertEqual(bytes(lastEffect(mouse, led: Razer.logoLed)), bytes(app), "not left dark")
    }

    func testARefusedOwnEffectFallsBackToTheApps() {
        let mouse = mouseLitAtLogo()
        primeEffect(mouse, led: Razer.logoLed, [1, 0, 0, 1, 0, 0, 255]) // blue
        let isBlueWrite: (RazerReport) -> Bool = { $0.commandClass == 0x0F && $0.commandId == 0x02 && $0.arguments[8] == 255 }
        let brightnessRefusal = mouse.refuse
        mouse.refuse = { brightnessRefusal($0) || isBlueWrite($0) }
        let app = RazerCommands.setStatic(led: Razer.logoLed, rgb: RGB(r: 0x44, g: 0xD6, b: 0x2C))
        let record = DeviceTestSteps.lighting(mouse, sweep: DeviceProbe.brightnessSweep(mouse), restoreEffect: [app],
                                              seconds: 0, wait: { _ in })
        XCTAssertEqual(bytes(lastEffect(mouse, led: Razer.logoLed)), bytes(app), "never left red")
        XCTAssertEqual(record.data?.restored, true)
    }

    func testTheEffectIsReadBeforeAnythingChanges() {
        let mouse = mouseLitAtLogo()
        primeEffect(mouse, led: Razer.logoLed, [3])
        _ = DeviceTestSteps.lighting(mouse, sweep: DeviceProbe.brightnessSweep(mouse),
                                     restoreEffect: [RazerCommands.setNone(led: Razer.logoLed)], seconds: 0, wait: { _ in })
        let firstWrite = mouse.sent.firstIndex { $0.commandClass == 0x0F && $0.commandId & 0x80 == 0 }
        let read = mouse.sent.firstIndex { $0.commandClass == 0x0F && $0.commandId == 0x82 }
        XCTAssertNotNil(read)
        XCTAssertLessThan(read ?? .max, firstWrite ?? .max)
        XCTAssertEqual(bytes(lastEffect(mouse, led: Razer.logoLed)), bytes(RazerCommands.setSpectrum(led: Razer.logoLed)))
    }
}

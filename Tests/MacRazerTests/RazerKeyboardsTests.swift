// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class RazerKeyboardsTests: XCTestCase {
    /// The Cynosa Chroma's interfaces as `ioreg` lists them. Its control interface reports the
    /// Mouse usage, with the 90-byte feature report a Razer mouse has.
    private func cynosaChroma(location: Int = 0x1100000, name: String = "Razer Cynosa Chroma") -> [HIDInterfaceInfo] {
        [
            .init(pid: 0x022A, locationID: location, usagePage: 0x01, usage: 0x06, maxFeatureReportSize: 0, productName: name),
            .init(pid: 0x022A, locationID: location, usagePage: 0x01, usage: 0x06, maxFeatureReportSize: 1, productName: name),
            .init(pid: 0x022A, locationID: location, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90, productName: name),
        ]
    }

    private func cobraDongle() -> [HIDInterfaceInfo] {
        [
            .init(pid: 0x00DB, locationID: 0x2100000, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90),
            .init(pid: 0x00DB, locationID: 0x2100000, usagePage: 0x59, usage: 0x01, maxFeatureReportSize: 51),
        ]
    }

    func testCynosaChromaIsVerifiedWithItsTransactionId() {
        let info = RazerKeyboards.info(pid: 0x022A)
        XCTAssertEqual(info?.verified, true)
        XCTAssertEqual(info?.transactionId, 0x3F)
        XCTAssertEqual(RazerKeyboards.info(pid: 0x02A1)?.transactionId, 0x1F, "Ornata V3")
    }

    /// No row may also be a mouse: a PID in both tables would rank first for the mouse.
    func testNoKeyboardIsInTheMouseRegistry() {
        for kb in RazerKeyboards.known {
            XCTAssertNil(RazerDevices.info(pid: kb.pid), kb.name)
        }
    }

    func testStaticColourGoesToTheBacklight() {
        let report = RazerKeyboards.report(for: .staticColor, color: RGB(r: 0x90, g: 0xEE, b: 0x90))
        XCTAssertEqual(report.commandClass, 0x0F)
        XCTAssertEqual(report.commandId, 0x02)
        XCTAssertEqual(Array(report.arguments[0..<9]), [0x01, 0x05, 0x01, 0x00, 0x00, 0x01, 0x90, 0xEE, 0x90])
    }

    func testBreathingGoesToTheBacklight() {
        // razerkbd_driver.c sends the Cynosa Chroma extended-matrix breathing_single on BACKLIGHT_LED.
        let report = RazerKeyboards.report(for: .breathing, color: RGB(r: 0x90, g: 0xEE, b: 0x90))
        XCTAssertEqual(report.dataSize, 0x09)
        XCTAssertEqual(Array(report.arguments[0..<9]), [0x01, 0x05, 0x02, 0x01, 0x00, 0x01, 0x90, 0xEE, 0x90])
    }

    func testColourPickRightAfterBreathingKeepsBreathing() {
        // No keyboard plugged in here: start() never runs, so the writes go nowhere and fail.
        let keyboard = KeyboardController()
        keyboard.setEffect(.breathing)
        keyboard.setColor(RGB(r: 1, g: 2, b: 3))
        XCTAssertEqual(keyboard.latestLighting.effect, .breathing,
                       "builds on the effect just picked, before the keyboard answers")
        XCTAssertEqual(keyboard.latestLighting.color, RGB(r: 1, g: 2, b: 3))

        let deadline = Date().addingTimeInterval(2)
        while keyboard.latestLighting != keyboard.lighting, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(keyboard.latestLighting, .unknown, "failed writes leave nothing pending")
    }

    func testUnknownSavedEffectKeepsTheRestOfTheLighting() throws {
        let json = #"{"effect":"Sparkle","color":{"r":1,"g":2,"b":3},"brightness":40,"waveSpeed":8}"#
        let lighting = try JSONDecoder().decode(KeyboardLighting.self, from: Data(json.utf8))
        XCTAssertNil(lighting.effect)
        XCTAssertEqual(lighting.color, RGB(r: 1, g: 2, b: 3))
        XCTAssertEqual(lighting.brightness, 40)
        XCTAssertEqual(lighting.waveSpeed, 8)
        let saved = KeyboardLighting(effect: .breathing, color: RGB(r: 1, g: 2, b: 3), brightness: 40)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardLighting.self, from: JSONEncoder().encode(saved)), saved)
    }

    func testEveryEffectTargetsTheBacklight() {
        for effect in LightingEffect.allCases {
            XCTAssertEqual(RazerKeyboards.report(for: effect, color: RGB(r: 0, g: 0, b: 0)).arguments[1],
                           Razer.backlightLed, effect.rawValue)
        }
    }

    func testPicksTheKeyboardControlInterfaceNextToAMouse() {
        let interfaces = cobraDongle() + cynosaChroma()
        let idx = RazerKeyboards.controlInterfaceIndex(interfaces: interfaces)
        XCTAssertEqual(idx.map { interfaces[$0].pid }, 0x022A)
        XCTAssertEqual(idx.map { interfaces[$0].maxFeatureReportSize }, 90)
    }

    func testNoKeyboardMeansNoPick() {
        XCTAssertNil(RazerKeyboards.controlInterfaceIndex(interfaces: cobraDongle()))
    }

    func testTwoKeyboardsPickTheLowerLocation() {
        let interfaces = cynosaChroma(location: 0x3000000) + cynosaChroma(location: 0x1000000)
        let idx = RazerKeyboards.controlInterfaceIndex(interfaces: interfaces)
        XCTAssertEqual(idx.map { interfaces[$0].locationID }, 0x1000000)
    }

    /// Even with a product string the name filter wouldn't catch, a keyboard in the table is
    /// never taken for the mouse.
    func testMouseSelectionSkipsAKnownKeyboard() {
        XCTAssertNil(HIDDeviceSelection.controlInterfaceIndex(interfaces: cynosaChroma(name: "")))
        let both = cynosaChroma(location: 0x0100000, name: "") + cobraDongle()
        let idx = HIDDeviceSelection.controlInterfaceIndex(interfaces: both)
        XCTAssertEqual(idx.map { both[$0].pid }, 0x00DB)
    }

    func testSynapseDetection() {
        XCTAssertTrue(SynapseDetector.isSynapse(bundleID: "com.razerzone.RazerSynapse", name: "Razer Synapse"))
        XCTAssertTrue(SynapseDetector.isSynapse(bundleID: "com.razerzone.rzdeviceengine", name: nil))
        XCTAssertTrue(SynapseDetector.isSynapse(bundleID: nil, name: "Razer Synapse Service"))
        XCTAssertFalse(SynapseDetector.isSynapse(bundleID: "com.apple.Safari", name: "Safari"))
        XCTAssertFalse(SynapseDetector.isSynapse(bundleID: nil, name: nil))
    }

    func testStoredLightingRoundTrips() throws {
        let lighting = KeyboardLighting(effect: .wave, color: RGB(r: 1, g: 2, b: 3), brightness: 20)
        let decoded = try JSONDecoder().decode(KeyboardLighting.self, from: JSONEncoder().encode(lighting))
        XCTAssertEqual(decoded, lighting)
        let unset = try JSONDecoder().decode(KeyboardLighting.self, from: JSONEncoder().encode(KeyboardLighting.unknown))
        XCTAssertNil(unset.effect)
    }

    func testMouseEffectsStayOnTheZeroLed() {
        XCTAssertEqual(RazerCommands.effect(.wave, color: RGB(r: 0, g: 0, b: 0)).arguments[1], Razer.zeroLed)
    }

    // MARK: Who may write

    func testWritesFreelyWithoutSynapse() {
        let kb = KeyboardController()
        kb.loadPreviewState(synapse: false)
        XCTAssertTrue(kb.canWrite)
        XCTAssertFalse(kb.leftToSynapse)
    }

    /// "Use MacRazer" starts off while Synapse runs, and goes either way.
    func testSynapseKeepsTheKeyboardUntilUseMacRazerIsOn() {
        let kb = KeyboardController()
        kb.loadPreviewState(synapse: true)
        XCTAssertTrue(kb.leftToSynapse)
        XCTAssertFalse(kb.canWrite)
        kb.choose(.macRazer)
        XCTAssertTrue(kb.canWrite)
        kb.choose(.synapse)
        XCTAssertFalse(kb.canWrite)
    }

    func testFollowingAsksForTheMouseOnlyWhenOn() {
        let kb = KeyboardController()
        kb.loadPreviewState(followsMouse: false)
        var asked = 0
        kb.mouseLighting = { asked += 1; return KeyboardLighting(effect: .wave, color: RGB(r: 0, g: 0, b: 0), brightness: 50) }
        kb.followMouse()
        XCTAssertEqual(asked, 0)
        kb.followsMouse = true
        kb.followMouse()
        XCTAssertEqual(asked, 1)
    }

    /// Picking MacRazer while following puts the mouse's lighting on, not the stored one.
    func testChoosingMacRazerWhileFollowingUsesTheMouse() {
        let kb = KeyboardController()
        kb.loadPreviewState(followsMouse: true, synapse: true)
        var asked = 0
        kb.mouseLighting = { asked += 1; return KeyboardLighting(effect: .wave, color: RGB(r: 0, g: 0, b: 0), brightness: 50) }
        kb.choose(.macRazer)
        XCTAssertEqual(asked, 1)
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class RazerAccessoriesTests: XCTestCase {
    /// The Cynosa Chroma's interfaces as `ioreg` lists them. Its control interface reports the
    /// Mouse usage, with the 90-byte feature report a Razer mouse has.
    private func cynosaChroma(location: Int = 0x1100000, name: String = "Razer Cynosa Chroma") -> [HIDInterfaceInfo] {
        [
            .init(pid: 0x022A, locationID: location, usagePage: 0x01, usage: 0x06, maxFeatureReportSize: 0, productName: name),
            .init(pid: 0x022A, locationID: location, usagePage: 0x01, usage: 0x06, maxFeatureReportSize: 1, productName: name),
            .init(pid: 0x022A, locationID: location, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90, productName: name),
        ]
    }

    /// A Firefly V2. Nobody here has its `ioreg`; a pad has a control interface carrying the
    /// 90-byte report like every other extended-matrix device.
    private func fireflyV2(location: Int = 0x1200000, name: String = "Razer Firefly V2") -> [HIDInterfaceInfo] {
        [
            .init(pid: 0x0C04, locationID: location, usagePage: 0x01, usage: 0x00, maxFeatureReportSize: 0, productName: name),
            .init(pid: 0x0C04, locationID: location, usagePage: 0x01, usage: 0x06, maxFeatureReportSize: 90, productName: name),
        ]
    }

    private func cobraDongle() -> [HIDInterfaceInfo] {
        [
            .init(pid: 0x00DB, locationID: 0x2100000, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90),
            .init(pid: 0x00DB, locationID: 0x2100000, usagePage: 0x59, usage: 0x01, maxFeatureReportSize: 51),
        ]
    }

    private let suite = "MacRazerTests.RazerAccessories"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func controller(_ pid: Int, location: Int = 1) -> AccessoryController {
        AccessoryController(id: .init(pid: pid, locationID: location), info: RazerAccessories.info(pid: pid)!,
                            defaults: defaults)
    }

    // MARK: The table

    func testCynosaChromaIsVerifiedWithItsTransactionId() {
        let info = RazerAccessories.info(pid: 0x022A)
        XCTAssertEqual(info?.verified, true)
        XCTAssertEqual(info?.kind, .keyboard)
        XCTAssertEqual(info?.transactionId, 0x3F)
        XCTAssertEqual(RazerAccessories.info(pid: 0x02A1)?.transactionId, 0x1F, "Ornata V3")
    }

    /// What the pad answered in a user's report, not OpenRazer's 0x3F and ZERO_LED for both.
    func testFireflyV2UsesWhatTheHardwareAnswered() throws {
        let pad = try XCTUnwrap(RazerAccessories.info(pid: 0x0C04))
        XCTAssertEqual(pad.kind, .mousepad)
        XCTAssertTrue(pad.verified)
        XCTAssertEqual(pad.transactionId, 0x1F)
        XCTAssertEqual(pad.effectLed, Razer.zeroLed)
        XCTAssertEqual(pad.brightnessLed, Razer.backlightLed)
        XCTAssertTrue(pad.isTested(.staticColor))
        for effect in [LightingEffect.breathing, .spectrum, .wave, .off] {
            XCTAssertFalse(pad.isTested(effect), effect.rawValue)
        }
    }

    /// Untested pads follow OpenRazer exactly, and the Goliathus ones have no wave there.
    func testUntestedPadsFollowOpenRazer() {
        let pads = RazerAccessories.known.filter { $0.kind == .mousepad && !$0.verified }
        XCTAssertFalse(pads.isEmpty)
        for pad in pads {
            XCTAssertEqual(pad.transactionId, 0x3F, pad.name)
            XCTAssertEqual(pad.effectLed, Razer.zeroLed, pad.name)
            XCTAssertEqual(pad.brightnessLed, Razer.zeroLed, pad.name)
            XCTAssertFalse(pad.isTested(.staticColor), pad.name)
        }
        XCTAssertEqual(RazerAccessories.info(pid: 0x0C01)?.supports(.wave), false, "Goliathus Chroma")
        XCTAssertEqual(RazerAccessories.info(pid: 0x0C08)?.supports(.wave), true, "Firefly V2 Pro")
        XCTAssertNil(RazerAccessories.info(pid: 0x0C00), "the original Firefly takes other commands")
    }

    func testKeyboardsLightTheBacklight() {
        for kb in RazerAccessories.known where kb.kind == .keyboard {
            XCTAssertEqual(kb.effectLed, Razer.backlightLed, kb.name)
            XCTAssertEqual(kb.brightnessLed, Razer.backlightLed, kb.name)
            XCTAssertEqual(kb.effects, LightingEffect.allCases, kb.name)
        }
    }

    /// No row may also be a mouse: a PID in both tables would rank first for the mouse.
    func testNoAccessoryIsInTheMouseRegistry() {
        for accessory in RazerAccessories.known {
            XCTAssertNil(RazerDevices.info(pid: accessory.pid), accessory.name)
        }
    }

    func testEveryPidIsListedOnce() {
        let pids = RazerAccessories.known.map(\.pid)
        XCTAssertEqual(pids.count, Set(pids).count)
    }

    // MARK: Reports

    func testStaticColourGoesToTheKeyboardBacklight() {
        let report = RazerAccessories.report(for: .staticColor, color: RGB(r: 0x90, g: 0xEE, b: 0x90),
                                             on: RazerAccessories.info(pid: 0x022A)!)
        XCTAssertEqual(report.commandClass, 0x0F)
        XCTAssertEqual(report.commandId, 0x02)
        XCTAssertEqual(Array(report.arguments[0..<9]), [0x01, 0x05, 0x01, 0x00, 0x00, 0x01, 0x90, 0xEE, 0x90])
    }

    func testBreathingGoesToTheKeyboardBacklight() {
        // razerkbd_driver.c sends the Cynosa Chroma extended-matrix breathing_single on BACKLIGHT_LED.
        let report = RazerAccessories.report(for: .breathing, color: RGB(r: 0x90, g: 0xEE, b: 0x90),
                                             on: RazerAccessories.info(pid: 0x022A)!)
        XCTAssertEqual(report.dataSize, 0x09)
        XCTAssertEqual(Array(report.arguments[0..<9]), [0x01, 0x05, 0x02, 0x01, 0x00, 0x01, 0x90, 0xEE, 0x90])
    }

    /// The same bytes the mouse path sent when the pad turned red in the report.
    func testStaticColourGoesToThePadsZeroLed() {
        let report = RazerAccessories.report(for: .staticColor, color: RGB(r: 0xFF, g: 0, b: 0),
                                             on: RazerAccessories.info(pid: 0x0C04)!)
        XCTAssertEqual(Array(report.arguments[0..<9]), [0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0xFF, 0x00, 0x00])
        XCTAssertEqual(report.arguments, RazerCommands.effect(.staticColor, color: RGB(r: 0xFF, g: 0, b: 0)).arguments)
    }

    func testMouseEffectsStayOnTheZeroLed() {
        XCTAssertEqual(RazerCommands.effect(.wave, color: RGB(r: 0, g: 0, b: 0)).arguments[1], Razer.zeroLed)
    }

    // MARK: Picking interfaces

    func testFindsEveryAccessoryNextToAMouse() {
        let interfaces = cobraDongle() + fireflyV2() + cynosaChroma()
        let found = RazerAccessories.controlInterfaceIndices(interfaces: interfaces)
        XCTAssertEqual(found.map { interfaces[$0].pid }, [0x022A, 0x0C04], "in LocationID order")
        XCTAssertEqual(found.map { interfaces[$0].maxFeatureReportSize }, [90, 90])
    }

    func testNoAccessoryMeansNoPick() {
        XCTAssertEqual(RazerAccessories.controlInterfaceIndices(interfaces: cobraDongle()), [])
    }

    func testTwoOfTheSameKeyboardAreTwoAccessories() {
        let interfaces = cynosaChroma(location: 0x3000000) + cynosaChroma(location: 0x1000000)
        let found = RazerAccessories.controlInterfaceIndices(interfaces: interfaces)
        XCTAssertEqual(found.map { interfaces[$0].locationID }, [0x1000000, 0x3000000])
    }

    /// Even with product strings the name filter wouldn't catch, a keyboard or pad in the
    /// table is never taken for the mouse, and the mouse still wins with all three plugged in.
    func testMouseSelectionSkipsKnownAccessories() {
        XCTAssertNil(HIDDeviceSelection.controlInterfaceIndex(interfaces: cynosaChroma(name: "")))
        XCTAssertNil(HIDDeviceSelection.controlInterfaceIndex(interfaces: fireflyV2(name: "")))
        let all = cynosaChroma(location: 0x0100000, name: "") + fireflyV2(location: 0x0200000, name: "") + cobraDongle()
        let idx = HIDDeviceSelection.controlInterfaceIndex(interfaces: all)
        XCTAssertEqual(idx.map { all[$0].pid }, 0x00DB)
    }

    // MARK: Saved settings

    func testUnknownSavedEffectKeepsTheRestOfTheLighting() throws {
        let json = #"{"effect":"Sparkle","color":{"r":1,"g":2,"b":3},"brightness":40,"waveSpeed":8}"#
        let lighting = try JSONDecoder().decode(AccessoryLighting.self, from: Data(json.utf8))
        XCTAssertNil(lighting.effect)
        XCTAssertEqual(lighting.color, RGB(r: 1, g: 2, b: 3))
        XCTAssertEqual(lighting.brightness, 40)
        XCTAssertEqual(lighting.waveSpeed, 8)
        let saved = AccessoryLighting(effect: .breathing, color: RGB(r: 1, g: 2, b: 3), brightness: 40)
        XCTAssertEqual(try JSONDecoder().decode(AccessoryLighting.self, from: JSONEncoder().encode(saved)), saved)
    }

    /// Each model keeps its own lighting, under the key keyboards used before pads joined.
    func testLightingIsSavedPerModel() {
        let kb = AccessoryLighting(effect: .wave, color: RGB(r: 1, g: 2, b: 3), brightness: 20)
        let pad = AccessoryLighting(effect: .staticColor, color: RGB(r: 9, g: 8, b: 7), brightness: 60)
        AccessoryController.store(kb, pid: 0x022A, defaults: defaults)
        AccessoryController.store(pad, pid: 0x0C04, defaults: defaults)
        XCTAssertEqual(AccessoryController.storedLighting(pid: 0x022A, defaults: defaults), kb)
        XCTAssertEqual(AccessoryController.storedLighting(pid: 0x0C04, defaults: defaults), pad)
        XCTAssertNotNil(defaults.data(forKey: "keyboardLighting.\(0x022A)"))
        XCTAssertEqual(controller(0x0C04).lighting, pad, "a new controller starts from what was saved")
        XCTAssertNil(AccessoryController.storedLighting(pid: 0x02A1, defaults: defaults))
    }

    func testFollowAndOwnerAreSavedPerModel() {
        let kb = controller(0x022A)
        kb.followsMouse = true
        kb.owner = .macRazer
        let pad = controller(0x0C04)
        XCTAssertFalse(pad.followsMouse)
        XCTAssertNil(pad.owner)
        XCTAssertTrue(controller(0x022A).followsMouse)
        XCTAssertEqual(controller(0x022A).owner, .macRazer)
    }

    /// The one keyboard switch there was before carries over to keyboards, not to pads.
    func testKeyboardsKeepTheOldSingleSettings() {
        defaults.set(true, forKey: AccessoryController.legacyFollowsMouseKey)
        defaults.set("macRazer", forKey: AccessoryController.legacyOwnerKey)
        XCTAssertFalse(controller(0x0C04).followsMouse)
        XCTAssertNil(controller(0x0C04).owner)
        XCTAssertTrue(controller(0x022A).followsMouse)
        XCTAssertEqual(controller(0x022A).owner, .macRazer)
        // Taken over once: a keyboard seen later starts fresh.
        XCTAssertFalse(controller(0x02A1).followsMouse)
        XCTAssertNil(controller(0x02A1).owner)
        XCTAssertTrue(controller(0x022A).followsMouse, "the first keyboard keeps them")
        // Turned off on the new switch, it stays off.
        controller(0x022A).followsMouse = false
        XCTAssertFalse(controller(0x022A).followsMouse)
    }

    // MARK: Writes

    func testColourPickRightAfterBreathingKeepsBreathing() {
        // Nothing plugged in: the writes go nowhere and fail.
        let keyboard = controller(0x022A)
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

    /// Nothing opened yet: no card, rather than controls that never work.
    func testAnAccessoryThatHasntOpenedIsNotShown() {
        XCTAssertFalse(controller(0x022A).isOpen)
    }

    func testAnEffectThePadLacksIsIgnored() {
        let goliathus = controller(0x0C01)
        goliathus.setEffect(.wave)
        XCTAssertNil(goliathus.latestLighting.effect)
    }

    /// A pad without a wave runs the mouse's wave as Spectrum.
    func testFollowingAWaveOnAPadWithoutOne() {
        let goliathus = controller(0x0C01)
        goliathus.mouseLighting = { AccessoryLighting(effect: .wave, color: RGB(r: 0, g: 0, b: 0), brightness: 50) }
        goliathus.followsMouse = true
        XCTAssertEqual(goliathus.latestLighting.effect, .spectrum)
        let pad = controller(0x0C04)
        pad.mouseLighting = goliathus.mouseLighting
        pad.followsMouse = true
        XCTAssertEqual(pad.latestLighting.effect, .wave)
    }

    // MARK: Who may write

    func testWritesFreelyWithoutSynapse() {
        let kb = controller(0x022A)
        kb.loadPreviewState(synapse: false)
        XCTAssertTrue(kb.canWrite)
        XCTAssertFalse(kb.leftToSynapse)
    }

    /// "Use MacRazer" starts off while Synapse runs, and goes either way, per accessory.
    func testSynapseKeepsAnAccessoryUntilUseMacRazerIsOn() {
        let kb = controller(0x022A), pad = controller(0x0C04)
        kb.loadPreviewState(synapse: true)
        pad.loadPreviewState(synapse: true)
        XCTAssertTrue(kb.leftToSynapse)
        XCTAssertFalse(kb.canWrite)
        kb.choose(.macRazer)
        XCTAssertTrue(kb.canWrite)
        XCTAssertFalse(pad.canWrite, "the pad's switch is its own")
        kb.choose(.synapse)
        XCTAssertFalse(kb.canWrite)
    }

    /// Turning "Follow mouse" on matches the mouse straight away; off, nothing asks.
    func testFollowingAsksForTheMouseOnlyWhenOn() {
        let kb = controller(0x022A)
        kb.loadPreviewState(followsMouse: false)
        var asked = 0
        kb.mouseLighting = { asked += 1; return AccessoryLighting(effect: .wave, color: RGB(r: 0, g: 0, b: 0), brightness: 50) }
        kb.followMouse()
        XCTAssertEqual(asked, 0)
        kb.followsMouse = true
        XCTAssertEqual(asked, 1)
    }

    /// Picking MacRazer while following puts the mouse's lighting on, not the stored one.
    func testChoosingMacRazerWhileFollowingUsesTheMouse() {
        let kb = controller(0x022A)
        kb.loadPreviewState(followsMouse: true, synapse: true)
        var asked = 0
        kb.mouseLighting = { asked += 1; return AccessoryLighting(effect: .wave, color: RGB(r: 0, g: 0, b: 0), brightness: 50) }
        kb.choose(.macRazer)
        XCTAssertEqual(asked, 1)
    }

    // MARK: The list

    func testThePreviewListKeepsItsOrderAndSynapse() {
        let list = Accessories()
        list.loadPreviewState(pids: [0x022A, 0x0C04, 0x02A1], followsMouse: [0x022A], synapse: true,
                              useMacRazer: [0x0C04])
        XCTAssertEqual(list.connected.map(\.info.pid), [0x022A, 0x0C04, 0x02A1])
        XCTAssertTrue(list.connected.allSatisfy(\.synapseRunning))
        XCTAssertEqual(list.connected.map(\.canWrite), [false, true, false])
        XCTAssertEqual(list.connected.map(\.followsMouse), [true, false, false])
        XCTAssertNotNil(list.accessory(.init(pid: 0x0C04, locationID: 1)))
        XCTAssertEqual(list.available.count, 3)
    }

    func testSynapseDetection() {
        XCTAssertTrue(SynapseDetector.isSynapse(bundleID: "com.razerzone.RazerSynapse", name: "Razer Synapse"))
        XCTAssertTrue(SynapseDetector.isSynapse(bundleID: "com.razerzone.rzdeviceengine", name: nil))
        XCTAssertTrue(SynapseDetector.isSynapse(bundleID: nil, name: "Razer Synapse Service"))
        XCTAssertFalse(SynapseDetector.isSynapse(bundleID: "com.apple.Safari", name: "Safari"))
        XCTAssertFalse(SynapseDetector.isSynapse(bundleID: nil, name: nil))
    }
}

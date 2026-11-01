// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class WaveSpeedTests: XCTestCase {
    func testSliderEndsAndMiddle() {
        XCTAssertEqual(WaveSpeed.byte(fromFraction: 0), WaveSpeed.slowest)
        XCTAssertEqual(WaveSpeed.byte(fromFraction: 1), WaveSpeed.fastest)
        XCTAssertEqual(WaveSpeed.byte(fromFraction: 0.5), WaveSpeed.standard, "the standard speed sits mid-slider")
        XCTAssertEqual(WaveSpeed.fraction(fromByte: WaveSpeed.standard), 0.5, accuracy: 0.001)
    }

    /// Lower bytes are faster, so moving the slider right must lower the byte.
    func testFasterIsALowerByte() {
        XCTAssertLessThan(WaveSpeed.byte(fromFraction: 0.8), WaveSpeed.byte(fromFraction: 0.2))
    }

    func testOutOfRangeValuesPin() {
        XCTAssertEqual(WaveSpeed.byte(fromFraction: -1), WaveSpeed.slowest)
        XCTAssertEqual(WaveSpeed.byte(fromFraction: 2), WaveSpeed.fastest)
        XCTAssertEqual(WaveSpeed.fraction(fromByte: 0xFF), 0)
        XCTAssertEqual(WaveSpeed.fraction(fromByte: 0x01), 1)
    }

    /// Each slider quarter multiplies the byte by the same factor (about 2.24), so the
    /// speed changes evenly along it.
    func testStepsAreGeometric() {
        XCTAssertEqual(WaveSpeed.byte(fromFraction: 0.25), 89)
        XCTAssertEqual(WaveSpeed.byte(fromFraction: 0.75), 18)
    }

    func testRoundTripsEverySliderByte() {
        for byte in WaveSpeed.fastest...WaveSpeed.slowest {
            XCTAssertEqual(WaveSpeed.byte(fromFraction: WaveSpeed.fraction(fromByte: byte)), byte)
        }
    }

    func testWaveCommandCarriesTheSpeed() {
        let mouse = RazerCommands.effect(.wave, color: RGB(r: 0, g: 0, b: 0), waveSpeed: 0x10)
        XCTAssertEqual(mouse.arguments[4], 0x10)
        let keyboard = RazerAccessories.report(for: .wave, color: RGB(r: 0, g: 0, b: 0), waveSpeed: 0x40,
                                               on: RazerAccessories.info(pid: 0x022A)!)
        XCTAssertEqual(keyboard.arguments[1], Razer.backlightLed)
        XCTAssertEqual(keyboard.arguments[4], 0x40)
        XCTAssertEqual(RazerCommands.setWave().arguments[4], WaveSpeed.standard)
    }

    /// Lighting and profiles saved before the speed existed still decode, at the standard speed.
    func testOlderSavedDataDecodes() throws {
        let oldLighting = #"{"brightness":27,"effect":"Wave","color":{"r":38,"b":255,"g":89}}"#
        let lighting = try JSONDecoder().decode(AccessoryLighting.self, from: Data(oldLighting.utf8))
        XCTAssertNil(lighting.waveSpeed)
        XCTAssertEqual(lighting.effect, .wave)

        let profile = MouseProfile(name: "Old", dpi: 800, pollRate: 1000, brightness: 50, effect: "Wave",
                                   color: RGB(r: 0, g: 0, b: 0), buttonMappings: [:])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        json.removeValue(forKey: "waveSpeed")
        let decoded = try JSONDecoder().decode(MouseProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.waveSpeed)
    }

    func testSpokenValueNamesTheEndsAndTheMiddle() {
        XCTAssertEqual(WaveSpeed.spokenValue(fromFraction: 0), "Slowest")
        XCTAssertEqual(WaveSpeed.spokenValue(fromFraction: WaveSpeed.fraction(fromByte: WaveSpeed.standard)), "Standard")
        XCTAssertEqual(WaveSpeed.spokenValue(fromFraction: 1), "Fastest")
    }
}

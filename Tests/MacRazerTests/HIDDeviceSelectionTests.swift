// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class HIDDeviceSelectionTests: XCTestCase {
    /// The Cobra HyperSpeed dongle's real interface set, captured from `MacRazer info`
    /// on hardware.
    private func hyperSpeedDongle(location: Int = 0x2100000) -> [HIDInterfaceInfo] {
        [
            .init(pid: 0x00DB, locationID: location, usagePage: 0x01, usage: 0x06, maxFeatureReportSize: 0),
            .init(pid: 0x00DB, locationID: location, usagePage: 0x01, usage: 0x06, maxFeatureReportSize: 1),
            .init(pid: 0x00DB, locationID: location, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90),
            .init(pid: 0x00DB, locationID: location, usagePage: 0x59, usage: 0x01, maxFeatureReportSize: 51),
            .init(pid: 0x00DB, locationID: location, usagePage: 0x59, usage: 0x01, maxFeatureReportSize: 51),
        ]
    }

    /// A plausible Razer keyboard: unknown PID, keyboard usage, plus a big vendor-page
    /// control interface that outscores the mouse's on raw interface score.
    private func keyboard(pid: Int = 0x0226, location: Int = 0x1100000) -> [HIDInterfaceInfo] {
        [
            .init(pid: pid, locationID: location, usagePage: 0x01, usage: 0x06, maxFeatureReportSize: 0),
            .init(pid: pid, locationID: location, usagePage: 0xFF00, usage: 0x01, maxFeatureReportSize: 512),
        ]
    }

    func testPicksTheControlInterfaceOfTheOnlyDevice() {
        let interfaces = hyperSpeedDongle()
        let idx = HIDDeviceSelection.controlInterfaceIndex(interfaces: interfaces)
        XCTAssertEqual(idx, 2, "the maxFeature-90 Mouse interface is the control channel")
    }

    func testKnownMouseBeatsKeyboardWithHigherInterfaceScore() {
        // Keyboard first in the list, and its vendor-page interface scores 1512 vs the
        // mouse's 590 — the registry rank must still pick the mouse.
        let interfaces = keyboard() + hyperSpeedDongle()
        let idx = HIDDeviceSelection.controlInterfaceIndex(interfaces: interfaces)
        XCTAssertEqual(interfaces[idx!].pid, 0x00DB)
        XCTAssertEqual(interfaces[idx!].maxFeatureReportSize, 90)
    }

    func testUnknownMouseBeatsKeyboard() {
        // A mouse model missing from the registry still exposes a Mouse usage interface.
        let unknownMouse: [HIDInterfaceInfo] = [
            .init(pid: 0x0123, locationID: 0x3100000, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 90),
        ]
        let interfaces = keyboard() + unknownMouse
        let idx = HIDDeviceSelection.controlInterfaceIndex(interfaces: interfaces)
        XCTAssertEqual(interfaces[idx!].pid, 0x0123)
    }

    func testTwoIdenticalMiceResolveStablyByLocation() {
        let a = hyperSpeedDongle(location: 0x2100000)
        let b = hyperSpeedDongle(location: 0x2200000)
        let forward = HIDDeviceSelection.controlInterfaceIndex(interfaces: a + b)
        let reversed = HIDDeviceSelection.controlInterfaceIndex(interfaces: b + a)
        XCTAssertEqual((a + b)[forward!].locationID, 0x2100000, "lowest location wins")
        XCTAssertEqual((b + a)[reversed!].locationID, 0x2100000, "…regardless of enumeration order")
    }

    func testNoControlCapableInterfaceReturnsNil() {
        let interfaces: [HIDInterfaceInfo] = [
            .init(pid: 0x00DB, locationID: 1, usagePage: 0x01, usage: 0x02, maxFeatureReportSize: 8),
            .init(pid: 0x0226, locationID: 2, usagePage: 0x01, usage: 0x06, maxFeatureReportSize: 0),
        ]
        XCTAssertNil(HIDDeviceSelection.controlInterfaceIndex(interfaces: interfaces))
    }

    func testAnUnnamedUnknownDeviceIsUsableWhenItIsTheOnlyOne() {
        // Nothing better attached and no product string to rule it out: still bind the best
        // control-capable interface rather than reporting "not found" (unknown future mice
        // may look like this). A named keyboard is skipped; see the next test.
        let interfaces = keyboard()
        let idx = HIDDeviceSelection.controlInterfaceIndex(interfaces: interfaces)
        XCTAssertEqual(interfaces[idx!].maxFeatureReportSize, 512)
    }

    func testANamedKeyboardIsNeverTakenForTheMouse() {
        let named = keyboard().map {
            HIDInterfaceInfo(pid: $0.pid, locationID: $0.locationID, usagePage: $0.usagePage, usage: $0.usage,
                             maxFeatureReportSize: $0.maxFeatureReportSize, productName: "Razer BlackWidow V4 Pro")
        }
        XCTAssertNil(HIDDeviceSelection.controlInterfaceIndex(interfaces: named),
                     "alone, it must not show as a mouse or get the support prompt")
        let interfaces = named + hyperSpeedDongle()
        XCTAssertEqual(interfaces[HIDDeviceSelection.controlInterfaceIndex(interfaces: interfaces)!].pid, 0x00DB)
    }

    func testARegisteredMouseIsKeptWhateverItsName() {
        let renamed = hyperSpeedDongle().map {
            HIDInterfaceInfo(pid: $0.pid, locationID: $0.locationID, usagePage: $0.usagePage, usage: $0.usage,
                             maxFeatureReportSize: $0.maxFeatureReportSize, productName: "Razer Keyboard Receiver")
        }
        XCTAssertEqual(HIDDeviceSelection.controlInterfaceIndex(interfaces: renamed), 2)
    }

    // MARK: Mouse or not, by name

    func testKeyboardsAndAccessoriesAreNotMice() {
        for name in ["Razer BlackWidow V4 Pro", "Razer Huntsman Mini", "Razer Ornata V3", "Razer Tartarus Pro",
                     "Razer Blade 15", "Razer Pro Type Ultra", "Razer Kraken V3 Pro"] {
            XCTAssertFalse(HIDDeviceSelection.couldBeMouse(productName: name), name)
        }
    }

    func testMiceStayMice() {
        // The registry's names, plus older ones that share words with other product lines.
        let names = RazerDevices.known.map(\.name) + ["Razer DeathAdder Chroma", "Razer Mamba Chroma",
                                                       "Razer Naga Trinity", "Razer Orochi V2",
                                                       // A mouse on the dock, if it shows as the dock.
                                                       "Razer Mouse Dock Pro"]
        for name in names {
            XCTAssertTrue(HIDDeviceSelection.couldBeMouse(productName: name), name)
        }
    }
}

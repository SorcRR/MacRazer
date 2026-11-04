// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// A step for something the mouse doesn't have still shows, says so, and records it without
/// touching the mouse.
final class NotOnMouseTests: XCTestCase {
    /// Only a battery or lights can be missing, and only where the row already hides them and
    /// isn't asking for a test of them.
    func testTheRegistryOnlyMarksWhatTheRowAgreesWith() {
        for row in RazerDevices.known where !row.notOnMouse.isEmpty {
            let name = row.name
            XCTAssertTrue(row.notOnMouse.isSubset(of: [.battery, .lighting]), name)
            if row.notOnMouse.contains(.battery) { XCTAssertFalse(row.hasBattery, name) }
            if row.notOnMouse.contains(.lighting) { XCTAssertFalse(row.hasLighting, name) }
            XCTAssertTrue(row.notOnMouse.isDisjoint(with: row.unverified), "\(name): asks for a test of what it lacks")
        }
        XCTAssertEqual(RazerDevices.notOnMouse(pid: 0x00B8), [.lighting], "Viper V3 HyperSpeed")
        XCTAssertEqual(RazerDevices.notOnMouse(pid: 0x0067), [.battery], "Naga Trinity")
        XCTAssertEqual(RazerDevices.notOnMouse(pid: 0x0039), [], "Orochi 2013: AA cells, the app just can't read them")
        XCTAssertEqual(RazerDevices.notOnMouse(pid: 0x9999), [], "a mouse not on record gets every step")
    }

    private func report(pid: Int) -> DeviceReport {
        var report = DeviceTestModel.emptyReport(pid: pid, name: "Mouse", interfaces: [], control: nil, identify: .init())
        DeviceTestModel.markNotOnMouse(&report)
        return report
    }

    func testTheReportSaysWhatTheMouseLacks() {
        let unlit = report(pid: 0x00B8)
        XCTAssertEqual(unlit.lighting.outcome, .notSupported)
        XCTAssertEqual(unlit.lighting.error, DeviceTestModel.notOnMouseNote(.lighting))
        XCTAssertNil(unlit.lighting.data, "nothing was sent to the mouse")
        XCTAssertEqual(unlit.battery.outcome, .skipped, "the battery step still runs")

        let wired = report(pid: 0x0067)
        XCTAssertEqual(wired.battery.outcome, .notSupported)
        XCTAssertEqual(wired.battery.error, DeviceTestModel.notOnMouseNote(.battery))
        XCTAssertEqual(wired.lighting.outcome, .skipped)
    }

    /// "Not on this mouse" is an answer, so it doesn't make the report partial.
    func testItDoesNotMakeTheReportPartial() {
        let verdict = DeviceTestVerdict.make(knownFullySupported: true, steps: [
            ("Identify", .passed), ("Battery", .passed), ("DPI", .passed), ("Polling rate", .passed),
            ("Lighting", .notSupported),
        ])
        XCTAssertEqual(verdict.kind, .confirmed)
    }

    @MainActor func testTheStepKnowsOnlyOnceTheMouseIsIdentified() {
        let model = DeviceTestModel(controller: MouseController(), permissions: PermissionsModel(), reportEndpoint: nil)
        XCTAssertNil(model.notOnMouse(.lighting), "no report yet")
        model.loadPreview(.lighting, pid: 0x00B8, ranSteps: false)
        XCTAssertEqual(model.notOnMouse(.lighting), .lighting)
        XCTAssertNil(model.notOnMouse(.battery))
        XCTAssertNil(model.notOnMouse(.dpi))
    }
}

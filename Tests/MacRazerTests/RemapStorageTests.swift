// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// 0.9.0 and earlier decode a remap table all or nothing. Newer actions are kept apart so an
/// older build still reads the rest, remaps and profiles alike.
final class RemapStorageTests: XCTestCase {
    private let table: [Int: RemapAction] = [
        3: .keystroke(keyCode: 8, modifiers: 0, name: "C"),
        4: .doubleClick,
        -13: .hyperShift,
        ButtonRemapper.hyperShiftKey(3): .dpiStage(up: true),
    ]

    func testSplitKeepsOnlyOldActionsInTheOldTable() {
        let (legacy, extended) = RemapStorage.split(table)
        XCTAssertEqual(Set(legacy.keys), [3, 4])
        XCTAssertEqual(Set(extended.keys), [-13, ButtonRemapper.hyperShiftKey(3)])
        XCTAssertEqual(RemapStorage.merge(legacy: legacy, extended: extended), table)
    }

    func testHardwareControlsAndTheHyperShiftLayerStayOutOfTheOldTable() {
        let keys: [Int: RemapAction] = [
            -1: .doubleClick, // the DPI button, which 0.9.0 lists
            -13: .doubleClick, // the side trigger, which it doesn't
            ButtonRemapper.hyperShiftKey(3): .keystroke(keyCode: 8, modifiers: 0, name: "C"),
        ]
        let (legacy, extended) = RemapStorage.split(keys)
        XCTAssertEqual(Set(legacy.keys), [-1])
        XCTAssertEqual(Set(extended.keys), [-13, ButtonRemapper.hyperShiftKey(3)])
    }

    func testAnOlderBuildsEditWinsOverAStaleNewerAction() {
        let merged = RemapStorage.merge(legacy: [4: .doubleClick], extended: [4: .disabled, 5: .disabled])
        XCTAssertEqual(merged, [4: .doubleClick, 5: .disabled])
    }

    func testAnUnreadableNewerActionSkipsOnlyItself() throws {
        let json = #"{"5":{"disabled":{}},"6":{"somethingFromLater":{}}}"#
        let extended = try JSONDecoder().decode(RemapStorage.Extended.self, from: Data(json.utf8))
        XCTAssertEqual(extended.table, [5: .disabled])
    }

    func testAProfileStaysReadableAsTheOldFormat() throws {
        var profile = MouseProfile(name: "Work", dpi: 1600, pollRate: 1000, brightness: 80, effect: "Static",
                                   color: RGB(r: 1, g: 2, b: 3), buttonMappings: table)
        let data = try JSONEncoder().encode([profile])
        // What 0.9.0 reads: `buttonMappings` as a plain table, every action one it knows.
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]]).first
        let old = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object?["buttonMappings"]))
        XCTAssertEqual(try JSONDecoder().decode([Int: RemapAction].self, from: old).count, 2)
        // And this build gets every remap back.
        let back = try JSONDecoder().decode([MouseProfile].self, from: data)
        XCTAssertEqual(back.first?.buttonMappings, table)
        profile.buttonMappings = [3: .doubleClick]
        XCTAssertEqual(profile.buttonMappings, [3: .doubleClick])
    }

    func testRemapperSavesNewerActionsApart() throws {
        let suite = "RemapStorageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let remapper = ButtonRemapper(defaults: defaults)
        remapper.setActiveDevice("MOUSE", deviceID: 0x00DB)
        remapper.setMappings([3: .doubleClick, 4: .disabled])
        let old = try XCTUnwrap(defaults.data(forKey: "buttonMappings-MOUSE"))
        XCTAssertEqual(try JSONDecoder().decode([Int: RemapAction].self, from: old), [3: .doubleClick])
        XCTAssertNotNil(defaults.data(forKey: "buttonMappingsExtended-MOUSE"))
        let again = ButtonRemapper(defaults: defaults)
        again.setActiveDevice("MOUSE", deviceID: 0x00DB)
        XCTAssertEqual(again.mappings, [3: .doubleClick, 4: .disabled])
    }
}

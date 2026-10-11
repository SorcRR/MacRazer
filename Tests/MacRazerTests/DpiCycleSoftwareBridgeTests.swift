// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
import CoreGraphics
@testable import MacRazer

final class DpiCycleSoftwareBridgeTests: XCTestCase {
    private func remapper(_ suite: String = #function) -> (ButtonRemapper, UserDefaults) {
        let defaults = UserDefaults(suiteName: "MacRazerTests.\(suite)")!
        defaults.removePersistentDomain(forName: "MacRazerTests.\(suite)")
        return (ButtonRemapper(defaults: defaults), defaults)
    }

    func testSoftwareActionIsPerDeviceAndPersists() {
        let (first, defaults) = remapper()
        first.setActiveDevice("PM2533", deviceID: 0x00BA)
        let action = RemapAction.mediaKey(code: 16, name: "Play / Pause")
        first.saveDpiSoftwareAction(action)

        let second = ButtonRemapper(defaults: defaults)
        second.setActiveDevice("PM2533", deviceID: 0x00BA)
        XCTAssertEqual(second.dpiCycleSoftwareAction, action)
        second.saveDpiSoftwareAction(nil)
        XCTAssertNil(defaults.data(forKey: "dpiCycleSoftwareAction-PM2533"))
    }

    func testBridgeConfirmationAndRestoreGate() {
        let (remapper, _) = remapper()
        remapper.setActiveDevice("PM2533", deviceID: 0x00BA)
        XCTAssertFalse(remapper.shouldRestoreDpiBridge(binding: .dpiCycle, connected: true,
                                                       bluetooth: true, alreadyAttempted: false))
        remapper.saveDpiSoftwareAction(.mediaKey(code: 16, name: "Play / Pause"))
        XCTAssertTrue(remapper.shouldRestoreDpiBridge(binding: .dpiCycle, connected: true,
                                                      bluetooth: true, alreadyAttempted: false))
        remapper.confirmDpiBridge(binding: .softwareBridge)
        XCTAssertTrue(remapper.dpiBridgeBindingConfirmed)
        remapper.confirmDpiBridge(binding: .dpiCycle)
        XCTAssertFalse(remapper.dpiBridgeBindingConfirmed)
    }

    func testReapplyingSavedActionDoesNotCountAsManualChange() {
        let (remapper, _) = remapper()
        remapper.setActiveDevice("PM2533", deviceID: 0x00BA)
        var manualChanges = 0
        remapper.onManualChange = { manualChanges += 1 }
        let action = RemapAction.mediaKey(code: 16, name: "Play / Pause")

        remapper.saveDpiSoftwareAction(action)
        remapper.saveDpiSoftwareAction(action)
        XCTAssertEqual(manualChanges, 1)

        remapper.saveDpiSoftwareAction(.doubleClick)
        XCTAssertEqual(manualChanges, 2)
    }

    func testSoftwareActionMigratesFromPidFallbackToSerialKey() throws {
        let oldKey = "test-pid-\(UUID().uuidString)"
        let newKey = "test-serial-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        let source = "dpiCycleSoftwareAction-\(oldKey)"
        let destination = "dpiCycleSoftwareAction-\(newKey)"
        defer {
            defaults.removeObject(forKey: source)
            defaults.removeObject(forKey: destination)
        }
        let action = RemapAction.mediaKey(code: 16, name: "Play / Pause")
        defaults.set(try JSONEncoder().encode(action), forKey: source)

        MouseController.migratePerDeviceData(from: oldKey, to: newKey)

        XCTAssertNil(defaults.object(forKey: source))
        // Compare the decoded action, not the bytes: JSONEncoder doesn't guarantee key order.
        XCTAssertEqual(try defaults.data(forKey: destination).map { try JSONDecoder().decode(RemapAction.self, from: $0) },
                       action)
    }

    func testKeyboardTapMaskIsOptIn() {
        let mouseOnly = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        let keyboard = mouseOnly | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        XCTAssertFalse(ButtonRemapper.includesKeyboardEvents(mouseOnly))
        XCTAssertTrue(ButtonRemapper.includesKeyboardEvents(keyboard))
    }
}

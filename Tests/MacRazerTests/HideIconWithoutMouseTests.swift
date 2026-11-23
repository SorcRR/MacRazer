// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The menu bar icon hides only when the setting is on and no Razer device is known.
final class HideIconWithoutMouseTests: XCTestCase {
    private func visible(connected: Bool = false, name: String? = nil,
                         bluetooth: BluetoothMouseStatus? = nil, accessory: Bool = false,
                         hide: Bool) -> Bool {
        MouseController.iconVisible(connected: connected, deviceName: name, bluetoothMouse: bluetooth,
                                    accessoryConnected: accessory, hideWithoutMouse: hide)
    }

    func testSettingOffAlwaysShows() {
        XCTAssertTrue(visible(hide: false))
    }

    func testNoMouseHides() {
        XCTAssertFalse(visible(hide: true))
    }

    func testReconnectShowsAgain() {
        XCTAssertTrue(visible(connected: true, name: "Viper V2", hide: true))
    }

    func testSleepingMouseKeepsIcon() {
        XCTAssertTrue(visible(connected: false, name: "Viper V2", hide: true))
    }

    func testBluetoothMouseKeepsIcon() {
        XCTAssertTrue(visible(bluetooth: .connecting(name: "Cobra HS"), hide: true))
    }

    func testKeyboardAloneKeepsIcon() {
        XCTAssertTrue(visible(accessory: true, hide: true))
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class ConnectionSoundSettingsTests: XCTestCase {
    func testControllerOwnsAndPersistsConnectionSoundPreference() {
        let defaults = UserDefaults.standard
        let key = MouseController.connectionSoundsEnabledKey
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue { defaults.set(previousValue, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        let controller = MouseController()
        XCTAssertTrue(controller.connectionSoundsEnabled)

        controller.connectionSoundsEnabled = false
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)
        XCTAssertFalse(MouseController().connectionSoundsEnabled)

        controller.connectionSoundsEnabled = true
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
    }

    func testDisabledConnectionSoundDoesNotInvokePlayback() {
        var playbackInvoked = false

        MouseController.playConnectionSoundIfEnabled(false) {
            playbackInvoked = true
        }

        XCTAssertFalse(playbackInvoked)
    }

    func testEnabledConnectionSoundInvokesPlayback() {
        var playbackInvoked = false

        MouseController.playConnectionSoundIfEnabled(true) {
            playbackInvoked = true
        }

        XCTAssertTrue(playbackInvoked)
    }
}

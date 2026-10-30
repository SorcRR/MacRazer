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

    /// Goes through the controller's real `playSound`, so it fails if the setting stops
    /// gating playback, not just if a helper breaks.
    func testSettingGatesConnectionSounds() {
        let key = MouseController.connectionSoundsEnabledKey
        let previousValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousValue { UserDefaults.standard.set(previousValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let controller = MouseController()
        var played: [Bool] = []
        controller.playConnectionSound = { played.append($0) }

        controller.connectionSoundsEnabled = false
        controller.playSound(connected: true)
        controller.playSound(connected: false)
        XCTAssertEqual(played, [], "muted: no sound either way")

        controller.connectionSoundsEnabled = true
        controller.playSound(connected: true)
        controller.playSound(connected: false)
        XCTAssertEqual(played, [true, false])
    }
}

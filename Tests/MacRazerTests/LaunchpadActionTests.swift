// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import XCTest
@testable import MacRazer

/// The Launchpad action: which app it opens (Apps on macOS 26, Launchpad before), what the
/// menus call it, how it's saved, and that it goes out through the action seam like any other,
/// so no test ever opens an app.
final class LaunchpadActionTests: XCTestCase {
    /// Apps first: on macOS 26 it replaced Launchpad, and a Mac with it has no Launchpad.
    func testAppsIsTriedBeforeLaunchpad() {
        XCTAssertEqual(LaunchpadApp.bundleIDs, ["com.apple.apps.launcher", "com.apple.launchpad.launcher"])
        XCTAssertEqual(LaunchpadApp.installedBundleID { _ in true }, LaunchpadApp.appsBundleID)
        XCTAssertEqual(LaunchpadApp.installedBundleID { $0 == LaunchpadApp.launchpadBundleID },
                       LaunchpadApp.launchpadBundleID, "macOS 15 and earlier")
        XCTAssertNil(LaunchpadApp.installedBundleID { _ in false }, "neither: the action does nothing")
    }

    /// The menus say "Apps" where Apps is the app there, as macOS 26 names it, and "Launchpad"
    /// everywhere else.
    func testTheLabelFollowsTheAppThatIsInstalled() {
        XCTAssertEqual(LaunchpadApp.label(installed: LaunchpadApp.appsBundleID), "Apps")
        XCTAssertEqual(LaunchpadApp.label(installed: LaunchpadApp.launchpadBundleID), "Launchpad")
        XCTAssertEqual(LaunchpadApp.label(installed: nil), "Launchpad")
        XCTAssertEqual(RemapAction.launchpad.label, LaunchpadApp.label(installed: LaunchpadApp.installed))
    }

    /// Saved under a key of its own, so everything saved before it reads as it did.
    func testItIsSavedUnderItsOwnKey() throws {
        let encoded = try JSONEncoder().encode(RemapAction.launchpad)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"launchpad":{}}"#)
        XCTAssertEqual(try JSONDecoder().decode(RemapAction.self, from: encoded), .launchpad)
        let table: [Int: RemapAction] = [3: .launchpad, 4: .doubleClick]
        XCTAssertEqual(try JSONDecoder().decode([Int: RemapAction].self, from: JSONEncoder().encode(table)), table)
    }

    /// It's listed with the system presets, after the last of them.
    func testTheMenuListsItWithTheSystemPresets() {
        XCTAssertTrue(ButtonRemapper.presets.contains { $0.id == ButtonRemapper.launchpadMenuAnchor })
    }

    /// A button mapped to it fires it once per press, through the same seam as every action,
    /// and swallows the press and its release.
    func testAMappedButtonFiresIt() {
        final class Emitted { var actions: [RemapAction] = [] }
        let emitted = Emitted()
        let suite = "MacRazerTests.LaunchpadAction.\(#function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let r = ButtonRemapper(defaults: defaults, actionEmitter: { emitted.actions.append($0) })
        r.setMappings([3: .launchpad])
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                                mouseButton: CGMouseButton(rawValue: 3)!)!
            XCTAssertNil(r.handle(type: type, event: event), "swallowed")
        }
        XCTAssertEqual(emitted.actions, [.launchpad])
    }
}

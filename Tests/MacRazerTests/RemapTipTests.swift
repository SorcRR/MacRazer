// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The one tip note in Configure Buttons, after the first mapping that works.
final class RemapTipTests: XCTestCase {
    private static let suite = "MacRazerTests.RemapTip"
    private var defaults: UserDefaults { UserDefaults(suiteName: Self.suite)! }

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: Self.suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    func testDueOnTheFirstFireOnly() {
        RemapTip.start(defaults)
        XCTAssertEqual(RemapTip.state(defaults), .waiting)
        XCTAssertTrue(RemapTip.fired(defaults))
        XCTAssertEqual(RemapTip.state(defaults), .due)
        XCTAssertFalse(RemapTip.fired(defaults), "already due")
        RemapTip.markShown(defaults)
        XCTAssertFalse(RemapTip.fired(defaults), "shown once, never again")
        XCTAssertEqual(RemapTip.state(defaults), .done)
    }

    func testNeverForSomeoneWithMappingsAlready() {
        defaults.set(Data(), forKey: RemapTip.mappingsPrefix + "1532-00DB")
        RemapTip.start(defaults)
        XCTAssertEqual(RemapTip.state(defaults), .done)
        XCTAssertFalse(RemapTip.fired(defaults))
    }

    func testTheNoDeviceKeyDoesNotCount() {
        defaults.set(Data(), forKey: RemapTip.mappingsPrefix + "none")
        RemapTip.start(defaults)
        XCTAssertEqual(RemapTip.state(defaults), .waiting, "old builds' junk under the no-device key isn't a mapping")
    }

    func testDecidedOnce() {
        RemapTip.start(defaults)
        // A mapping saved after the first run doesn't take the note away.
        defaults.set(Data(), forKey: RemapTip.mappingsPrefix + "1532-00DB")
        RemapTip.start(defaults)
        XCTAssertEqual(RemapTip.state(defaults), .waiting)
    }

    func testTheRemapperRaisesItWhenAMappingFires() {
        var fired: [RemapAction] = []
        let remapper = ButtonRemapper(defaults: defaults, actionEmitter: { fired.append($0) })
        XCTAssertFalse(remapper.tipNoteDue)
        remapper.fireForTesting(.doubleClick)
        XCTAssertEqual(fired, [.doubleClick])
        XCTAssertTrue(remapper.tipNoteDue)
        remapper.markTipNoteShown()
        XCTAssertFalse(remapper.tipNoteDue)
        XCTAssertFalse(ButtonRemapper(defaults: defaults).tipNoteDue, "a relaunch doesn't bring it back")
    }

    func testNoneDoesNotCount() {
        let remapper = ButtonRemapper(defaults: defaults, actionEmitter: { _ in })
        remapper.fireForTesting(.passthrough)
        XCTAssertFalse(remapper.tipNoteDue)
    }
}

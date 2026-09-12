// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class UpdateAnnouncementTests: XCTestCase {
    func testAVersionChangeIsAnnounced() {
        XCTAssertTrue(UpdateAnnouncement.shouldAnnounce(
            lastRun: "0.3.0", current: "0.3.1", dismissed: nil, hasRunBefore: true))
    }

    func testTheSameVersionIsNot() {
        XCTAssertFalse(UpdateAnnouncement.shouldAnnounce(
            lastRun: "0.3.1", current: "0.3.1", dismissed: nil, hasRunBefore: true))
    }

    func testAFirstInstallIsNotAnUpdate() {
        // Nothing recorded and no trace of an older version: "Updated to 0.3.1" on the very
        // first launch is a claim about a release the user has never seen.
        XCTAssertFalse(UpdateAnnouncement.shouldAnnounce(
            lastRun: nil, current: "0.3.1", dismissed: nil, hasRunBefore: false))
        XCTAssertFalse(UpdateAnnouncement.shouldAnnounce(
            lastRun: "", current: "0.3.1", dismissed: nil, hasRunBefore: false))
    }

    func testTheUpgradeThatIntroducesTheFeatureStillAnnounces() {
        // The case that made this parameter necessary. Someone on 0.3.0 has no recorded
        // version, because 0.3.0 never wrote one — indistinguishable from a new install unless
        // you look for the traces an older run left. Without this, the release that ships the
        // announcement is the one release that never shows it.
        XCTAssertTrue(UpdateAnnouncement.shouldAnnounce(
            lastRun: nil, current: "0.3.1", dismissed: nil, hasRunBefore: true))
    }

    func testItStillOnlyHappensOnce() {
        // Having run before stops mattering the moment a version is recorded, so the launch
        // after the announcement is silent rather than repeating it forever.
        XCTAssertFalse(UpdateAnnouncement.shouldAnnounce(
            lastRun: "0.3.1", current: "0.3.1", dismissed: nil, hasRunBefore: true))
    }

    func testDismissingIsPerVersion() {
        XCTAssertFalse(UpdateAnnouncement.shouldAnnounce(
            lastRun: "0.3.0", current: "0.3.1", dismissed: "0.3.1", hasRunBefore: true))
        // The next release still gets to speak up.
        XCTAssertTrue(UpdateAnnouncement.shouldAnnounce(
            lastRun: "0.3.1", current: "0.3.2", dismissed: "0.3.1", hasRunBefore: true))
        // And dismissing wins over the upgrade case too, or a dismissal on the first launch
        // after upgrading would not stick.
        XCTAssertFalse(UpdateAnnouncement.shouldAnnounce(
            lastRun: nil, current: "0.3.1", dismissed: "0.3.1", hasRunBefore: true))
    }

    // MARK: Surviving until it is actually seen

    func testAnAnnouncementIsOwedUntilItIsDismissed() {
        // The launch that notices the change owes one...
        XCTAssertEqual(UpdateAnnouncement.pending(lastRun: "0.3.0", current: "0.3.1", dismissed: nil,
                                                  storedPending: nil, hasRunBefore: true), "0.3.1")
        // ...and every launch after still owes it, because the card waits for the popover to be
        // opened and a menu bar app can go days without that. Holding it in memory only meant a
        // reboot in between lost it, on exactly the automatic-install path it exists for.
        XCTAssertEqual(UpdateAnnouncement.pending(lastRun: "0.3.1", current: "0.3.1", dismissed: nil,
                                                  storedPending: "0.3.1", hasRunBefore: true), "0.3.1")
    }

    func testDismissingEndsIt() {
        XCTAssertNil(UpdateAnnouncement.pending(lastRun: "0.3.1", current: "0.3.1", dismissed: "0.3.1",
                                                storedPending: nil, hasRunBefore: true))
    }

    func testNothingIsOwedWhenNothingChanged() {
        XCTAssertNil(UpdateAnnouncement.pending(lastRun: "0.3.1", current: "0.3.1", dismissed: nil,
                                                storedPending: nil, hasRunBefore: true))
    }

    func testAPendingAnnouncementForAnotherVersionIsStale() {
        // Rolled back, or updated again before reading it. Either way the version running is
        // the only one worth talking about, and 0.3.1's card on a 0.3.0 app would be wrong.
        XCTAssertEqual(UpdateAnnouncement.pending(lastRun: "0.3.1", current: "0.3.2", dismissed: nil,
                                                  storedPending: "0.3.1", hasRunBefore: true), "0.3.2")
        XCTAssertNil(UpdateAnnouncement.pending(lastRun: "0.3.0", current: "0.3.0", dismissed: nil,
                                                storedPending: "0.3.1", hasRunBefore: true))
    }

    func testAFirstInstallOwesNothing() {
        XCTAssertNil(UpdateAnnouncement.pending(lastRun: nil, current: "0.3.1", dismissed: nil,
                                                storedPending: nil, hasRunBefore: false))
    }

    func testADowngradeIsStillAChange() {
        // Rolling back to a DMG after a bad release is a version change like any other, and
        // the notes for what you are now running are the useful thing to offer.
        XCTAssertTrue(UpdateAnnouncement.shouldAnnounce(
            lastRun: "0.3.1", current: "0.3.0", dismissed: nil, hasRunBefore: true))
    }
}

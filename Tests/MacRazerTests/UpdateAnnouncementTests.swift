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

/// The throttle, and the one case that has to escape it.
@MainActor
final class CheckDueTests: XCTestCase {
    private let interval = UpdateChecker.checkInterval
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testNeverCheckedIsDue() {
        XCTAssertTrue(UpdateChecker.isCheckDue(lastChecked: nil, now: now, interval: interval,
                                               notesMissingForNewVersion: false))
    }

    func testWithinTheWindowIsNot() {
        XCTAssertFalse(UpdateChecker.isCheckDue(lastChecked: now.addingTimeInterval(-interval + 60),
                                                now: now, interval: interval,
                                                notesMissingForNewVersion: false))
    }

    func testPastTheWindowIs() {
        XCTAssertTrue(UpdateChecker.isCheckDue(lastChecked: now.addingTimeInterval(-interval - 1),
                                               now: now, interval: interval,
                                               notesMissingForNewVersion: false))
    }

    func testAFreshVersionWithNoNotesBeatsTheThrottle() {
        // What 0.4.0 shipped with. The old version checked minutes before the update, so the
        // throttle was wide open, and 0.3.0 never cached a body at all — the release that
        // introduced "What's new" showed its card with nothing behind it until the next check.
        XCTAssertTrue(UpdateChecker.isCheckDue(lastChecked: now.addingTimeInterval(-60),
                                               now: now, interval: interval,
                                               notesMissingForNewVersion: true))
    }

    func testItDoesNotBecomeACheckOnEveryLaunch() {
        // Once the forced check stores the body there are notes, and the throttle applies
        // again. Nothing here should make a version change mean an unthrottled app.
        XCTAssertFalse(UpdateChecker.isCheckDue(lastChecked: now.addingTimeInterval(-60),
                                                now: now, interval: interval,
                                                notesMissingForNewVersion: false))
    }
}

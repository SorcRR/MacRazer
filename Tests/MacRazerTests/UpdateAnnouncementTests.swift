// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class UpdateAnnouncementTests: XCTestCase {
    func testAVersionChangeIsAnnounced() {
        XCTAssertTrue(UpdateAnnouncement.shouldAnnounce(lastRun: "0.3.0", current: "0.3.1", dismissed: nil))
    }

    func testTheSameVersionIsNot() {
        XCTAssertFalse(UpdateAnnouncement.shouldAnnounce(lastRun: "0.3.1", current: "0.3.1", dismissed: nil))
    }

    func testAFirstInstallIsNotAnUpdate() {
        // Nothing recorded means nobody has run an older version here, and "Updated to 0.3.1"
        // on the very first launch is a lie about a release the user has never seen.
        XCTAssertFalse(UpdateAnnouncement.shouldAnnounce(lastRun: nil, current: "0.3.1", dismissed: nil))
        XCTAssertFalse(UpdateAnnouncement.shouldAnnounce(lastRun: "", current: "0.3.1", dismissed: nil))
    }

    func testDismissingIsPerVersion() {
        XCTAssertFalse(UpdateAnnouncement.shouldAnnounce(lastRun: "0.3.0", current: "0.3.1", dismissed: "0.3.1"))
        // The next release still gets to speak up.
        XCTAssertTrue(UpdateAnnouncement.shouldAnnounce(lastRun: "0.3.1", current: "0.3.2", dismissed: "0.3.1"))
    }

    func testADowngradeIsStillAChange() {
        // Rolling back to a DMG after a bad release is a version change like any other, and
        // the notes for what you are now running are the useful thing to offer.
        XCTAssertTrue(UpdateAnnouncement.shouldAnnounce(lastRun: "0.3.1", current: "0.3.0", dismissed: nil))
    }
}

/// The other half of "can I still read the notes after installing?": which cached body is
/// allowed to answer for the version now running.
@MainActor
final class InstalledNotesTests: XCTestCase {
    private let body = "A summary.\n\n### Added\n- **A thing.** It happened."

    func testNotesForTheVersionRunningAreShown() {
        let notes = UpdateChecker.notes(for: "0.3.1", cachedVersion: "0.3.1", cachedBody: body)
        XCTAssertEqual(notes?.sections.first?.items.first?.headline, "A thing.")
    }

    func testNotesCachedForAnotherVersionAreNot() {
        // The cache tracks the newest release the last check saw, which is not always what is
        // installed — someone who skipped 0.3.2 would otherwise read its notes in an About box
        // that says 0.3.1.
        XCTAssertNil(UpdateChecker.notes(for: "0.3.1", cachedVersion: "0.3.2", cachedBody: body))
        XCTAssertNil(UpdateChecker.notes(for: "0.3.1", cachedVersion: nil, cachedBody: body))
    }

    func testAReleaseWithNoBodyShowsNothingRatherThanAnEmptyPage() {
        XCTAssertNil(UpdateChecker.notes(for: "0.3.1", cachedVersion: "0.3.1", cachedBody: nil))
        XCTAssertNil(UpdateChecker.notes(for: "0.3.1", cachedVersion: "0.3.1", cachedBody: ""))
    }
}

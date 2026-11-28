// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// Closing the update card hides that version for a week, then it is offered again.
final class UpdateDismissalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    func testADismissalHoldsForAWeek() {
        XCTAssertTrue(UpdateChecker.isDismissed("0.11.0", dismissed: "0.11.0",
                                                dismissedAt: now, now: now))
        XCTAssertTrue(UpdateChecker.isDismissed("0.11.0", dismissed: "0.11.0",
                                                dismissedAt: now.addingTimeInterval(-6.9 * day), now: now))
    }

    func testTheCardIsBackAfterAWeek() {
        XCTAssertFalse(UpdateChecker.isDismissed("0.11.0", dismissed: "0.11.0",
                                                 dismissedAt: now.addingTimeInterval(-7 * day), now: now))
        XCTAssertFalse(UpdateChecker.isDismissed("0.11.0", dismissed: "0.11.0",
                                                 dismissedAt: now.addingTimeInterval(-30 * day), now: now))
    }

    func testOnlyTheDismissedVersionIsHidden() {
        XCTAssertFalse(UpdateChecker.isDismissed("0.12.0", dismissed: "0.11.0",
                                                 dismissedAt: now, now: now))
        XCTAssertFalse(UpdateChecker.isDismissed("0.11.0", dismissed: nil, dismissedAt: nil, now: now))
    }

    /// A clock set ahead when the card was closed must not hide it for longer than a week.
    func testADismissalDatedInTheFutureNoLongerHolds() {
        XCTAssertFalse(UpdateChecker.isDismissed("0.11.0", dismissed: "0.11.0",
                                                 dismissedAt: now.addingTimeInterval(365 * day), now: now))
    }

    /// Saved by a version that kept no date: it can only name a version already installed.
    func testADismissalWithoutADateNoLongerHolds() {
        XCTAssertFalse(UpdateChecker.isDismissed("0.11.0", dismissed: "0.11.0", dismissedAt: nil, now: now))
    }

    @MainActor
    func testDismissingRecordsTheDate() {
        let suite = "MacRazerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = Date()
        UpdateChecker(defaults: defaults).dismiss("0.11.0")
        XCTAssertEqual(defaults.string(forKey: "dismissedUpdateVersion"), "0.11.0")
        let at = defaults.object(forKey: "dismissedUpdateDate") as? Date
        XCTAssertNotNil(at)
        XCTAssertGreaterThanOrEqual(at ?? .distantPast, before)
    }
}

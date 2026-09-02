// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class AutoInstallPolicyTests: XCTestCase {
    /// Everything permitting an install, so each test can deny exactly one thing.
    private func conditions(
        version: String? = "2.0.0", enabled: Bool = true, canInstall: Bool = true,
        busy: Bool = false, popover: Bool = false
    ) -> AutoInstallPolicy.Conditions {
        .init(availableVersion: version, enabled: enabled, canInstallInPlace: canInstall,
              busy: busy, popoverVisible: popover)
    }

    func testInstallsWhenEverythingPermitsIt() {
        var p = AutoInstallPolicy()
        XCTAssertTrue(p.shouldInstall(conditions()))
    }

    func testEachConditionAloneIsEnoughToRefuse() {
        // Every one of these is a way to silently restart someone's app at a bad moment.
        for (name, c) in [
            ("no update available", conditions(version: nil)),
            ("setting off", conditions(enabled: false)),
            ("can't install in place", conditions(canInstall: false)),
            ("already installing", conditions(busy: true)),
            ("popover open", conditions(popover: true)),
        ] {
            var p = AutoInstallPolicy()
            XCTAssertFalse(p.shouldInstall(c), "should have refused: \(name)")
        }
    }

    func testOnlyAttemptsAVersionOnce() {
        var p = AutoInstallPolicy()
        XCTAssertTrue(p.shouldInstall(conditions()))
        // Every popover close re-asks. A payload that can't be installed must not be
        // re-downloaded each time to reach the same verdict.
        XCTAssertFalse(p.shouldInstall(conditions()))
        XCTAssertFalse(p.shouldInstall(conditions()))
    }

    func testANewerReleaseIsStillTriedAfterAnEarlierOneFailed() {
        // Attempts are keyed by version, not a single spent flag — otherwise one bad release
        // would disable automatic updates for every release after it.
        var p = AutoInstallPolicy()
        XCTAssertTrue(p.shouldInstall(conditions(version: "2.0.0")))
        XCTAssertFalse(p.shouldInstall(conditions(version: "2.0.0")))
        XCTAssertTrue(p.shouldInstall(conditions(version: "2.0.1")))
    }

    func testRetryLaterRearmsTheSameVersion() {
        // The transient case: a dropped connection must not cost automatic updates until the
        // user next relaunches, which for a login-item menu bar app can be weeks.
        var p = AutoInstallPolicy()
        XCTAssertTrue(p.shouldInstall(conditions()))
        XCTAssertFalse(p.shouldInstall(conditions()))
        p.retryLater("2.0.0")
        XCTAssertTrue(p.shouldInstall(conditions()))
    }

    func testRefusalDoesNotSpendTheAttempt() {
        // Being refused because the popover was open is not an attempt — the next close has to
        // still be able to install.
        var p = AutoInstallPolicy()
        XCTAssertFalse(p.shouldInstall(conditions(popover: true)))
        XCTAssertTrue(p.shouldInstall(conditions(popover: false)))
    }

    func testPermanentFailuresAreNotRetried() {
        let p = AutoInstallPolicy()
        // These verdicts don't change on a second download of the same release.
        XCTAssertTrue(p.isPermanent(UpdateInstallError.rejected(.wrongApp)))
        XCTAssertTrue(p.isPermanent(UpdateInstallError.rejected(.notNewer("1.0.0"))))
        XCTAssertTrue(p.isPermanent(UpdateInstallError.signatureInvalid))
        XCTAssertTrue(p.isPermanent(UpdateInstallError.notWritable))
    }

    func testTransientFailuresAreRetried() {
        let p = AutoInstallPolicy()
        // A busy volume, a disk that gets emptied, a half-written download — all worth
        // another go on the next opportunity.
        XCTAssertFalse(p.isPermanent(UpdateInstallError.mountFailed))
        XCTAssertFalse(p.isPermanent(UpdateInstallError.copyFailed("busy")))
        XCTAssertFalse(p.isPermanent(UpdateInstallError.swapFailed("in use")))
        // Not an install error at all: the download itself failed.
        XCTAssertFalse(p.isPermanent(URLError(.notConnectedToInternet)))
    }
}

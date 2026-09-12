// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The wiring between `UpdateChecker`'s decisions and the defaults they read.
///
/// Every decision here is a pure function tested elsewhere. This covers the part that was not
/// testable until the store could be injected, which is exactly where both of this feature's
/// shipped bugs were: an announcement kept only in memory, and then notes read from a cache
/// written by a version that had no such key.
@MainActor
final class UpdateCheckerStateTests: XCTestCase {
    // Made per test rather than in setUp: `setUp`/`tearDown` are nonisolated, and this class
    // has to be `@MainActor` to touch `UpdateChecker` at all.
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "MacRazerTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private var running: String { AppInfo.comparableVersion }

    func testAFirstRunAnnouncesNothingAndRecordsTheVersion() {
        withDefaults { defaults in
            let checker = UpdateChecker(defaults: defaults)
            checker.loadInstalledVersionState()
            XCTAssertNil(checker.justUpdatedTo)
            XCTAssertEqual(defaults.string(forKey: "lastRunVersion"), running)
        }
    }

    func testAVersionChangeAnnouncesOnce() {
        withDefaults { defaults in
            defaults.set("0.0.1", forKey: "lastRunVersion")
            defaults.set(true, forKey: "launchAtLoginDefaultApplied")

            let first = UpdateChecker(defaults: defaults)
            first.loadInstalledVersionState()
            XCTAssertEqual(first.justUpdatedTo, running)

            // Still owed on the next launch, because the card waits for the popover to be opened.
            let second = UpdateChecker(defaults: defaults)
            second.loadInstalledVersionState()
            XCTAssertEqual(second.justUpdatedTo, running)

            second.dismissAnnouncement()
            let third = UpdateChecker(defaults: defaults)
            third.loadInstalledVersionState()
            XCTAssertNil(third.justUpdatedTo, "a dismissal has to survive a relaunch")
        }
    }

    func testTheAnnouncementSurvivesARelaunchBeforeItIsSeen() {
        withDefaults { defaults in
            // The first bug: `justUpdatedTo` was derived once and held in memory while the version
            // was written to defaults immediately, so a reboot before opening the popover lost it.
            defaults.set("0.0.1", forKey: "lastRunVersion")
            defaults.set(true, forKey: "launchAtLoginDefaultApplied")
            UpdateChecker(defaults: defaults).loadInstalledVersionState()

            XCTAssertEqual(defaults.string(forKey: "pendingUpdateAnnouncement"), running,
                           "the announcement has to be written down, not just held")
        }
    }

    /// Also the migration path: these are the keys versions before this one wrote, and the
    /// first launch after upgrading has to read them rather than show nothing.
    func testNotesAreShownOnlyForTheVersionRunning() {
        withDefaults { defaults in
            defaults.set(running, forKey: "lastFoundUpdateVersion")
            defaults.set("A summary.\n\n### Added\n- **A thing.** It happened.", forKey: "lastFoundUpdateNotes")

            let checker = UpdateChecker(defaults: defaults)
            checker.loadInstalledVersionState()
            XCTAssertFalse(checker.installedNotes.isEmpty)

            defaults.set("99.0.0", forKey: "lastFoundUpdateVersion")
            let other = UpdateChecker(defaults: defaults)
            other.loadInstalledVersionState()
            XCTAssertTrue(other.installedNotes.isEmpty, "a cache about another release must not answer")
        }
    }

    func testAnUpgradeFromAVersionWithNoNotesCacheGoesStraightToTheNetwork() {
        withDefaults { defaults in
            // The second bug, reported from a real 0.3.0 install. 0.3.0 never wrote a notes cache,
            // so the row had nothing to open, and the old version's own check minutes earlier left
            // the throttle wide open for a day.
            defaults.set("0.0.1", forKey: "lastRunVersion")
            defaults.set(true, forKey: "launchAtLoginDefaultApplied")
            defaults.set(Date(), forKey: "lastUpdateCheckDate") // checked a moment ago

            let checker = UpdateChecker(defaults: defaults)
            checker.loadInstalledVersionState()

            XCTAssertNotNil(checker.justUpdatedTo)
            XCTAssertTrue(checker.installedNotes.isEmpty)
            XCTAssertTrue(UpdateChecker.isCheckDue(lastChecked: checker.lastCheckedAt,
                                                   now: Date(),
                                                   interval: 24 * 60 * 60,
                                                   notesMissingForNewVersion: checker.justUpdatedTo != nil
                                                       && checker.installedNotes.isEmpty),
                          "a fresh version with no notes must not wait out the throttle")
        }
    }

    func testABodylessReleaseIsNotRefetchedOnEveryLaunch() {
        // The exception exists for a cache written by an older version. A release with no body
        // leaves the notes nil no matter how often it is fetched, so without a record of the
        // attempt it would bypass the throttle at every launch for a request that cannot help.
        withDefaults { defaults in
            defaults.set("0.0.1", forKey: "lastRunVersion")
            defaults.set(true, forKey: "launchAtLoginDefaultApplied")
            defaults.set(Date(), forKey: "lastUpdateCheckDate")
            defaults.set(AppInfo.comparableVersion, forKey: "notesCheckedForVersion")

            let checker = UpdateChecker(defaults: defaults)
            checker.loadInstalledVersionState()
            XCTAssertNotNil(checker.justUpdatedTo)
            XCTAssertTrue(checker.installedNotes.isEmpty)
            XCTAssertFalse(checker.notesWorthFetchingForTesting,
                           "already asked for this version, so the throttle applies again")
        }
    }

    func testTheSpanComesFromTheCacheAndTheVersionYouCameFrom() {
        // The whole point, end to end through the defaults: 0.3.0 to 0.4.1 shows both releases
        // gained, not just the newest one.
        withDefaults { defaults in
            let running = AppInfo.comparableVersion
            defaults.set("0.0.1", forKey: "lastRunVersion")
            defaults.set(true, forKey: "launchAtLoginDefaultApplied")
            seed(defaults, [RemoteRelease(version: running, body: "Newest.\n\n### Fixed\n- **A fix.** Yes."),
                            RemoteRelease(version: "0.0.5", body: "Middle.\n\n### Added\n- **A feature.** Yes."),
                            RemoteRelease(version: "0.0.1", body: "Old.\n\n### Added\n- **Old news.** Yes.")])

            let checker = UpdateChecker(defaults: defaults)
            checker.loadInstalledVersionState()
            XCTAssertEqual(checker.installedNotes.map(\.version), [running, "0.0.5"],
                           "everything after the version they were on, up to the one running")
        }
    }

    func testAReleaseWithNoNotesIsNotGivenAnEmptyHeading() {
        withDefaults { defaults in
            let running = AppInfo.comparableVersion
            defaults.set("0.0.1", forKey: "lastRunVersion")
            defaults.set(true, forKey: "launchAtLoginDefaultApplied")
            seed(defaults, [RemoteRelease(version: running, body: "")])

            let checker = UpdateChecker(defaults: defaults)
            checker.loadInstalledVersionState()
            XCTAssertTrue(checker.installedNotes.isEmpty,
                          "a version heading with nothing under it says less than nothing")
        }
    }

    private func seed(_ defaults: UserDefaults, _ releases: [RemoteRelease]) {
        defaults.set(try! JSONEncoder().encode(releases), forKey: "cachedReleases")
    }

    func testAutoInstallDefaultsOffAndPersists() {
        withDefaults { defaults in
            XCTAssertFalse(UpdateChecker(defaults: defaults).autoInstallEnabled)
            let checker = UpdateChecker(defaults: defaults)
            checker.autoInstallEnabled = true
            XCTAssertTrue(UpdateChecker(defaults: defaults).autoInstallEnabled,
                          "the setting has to outlive the object that set it")
        }
    }
}

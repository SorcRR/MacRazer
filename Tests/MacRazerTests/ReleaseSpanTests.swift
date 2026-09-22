// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class ReleaseSpanTests: XCTestCase {
    /// Deliberately out of order, and with the two kinds of release that must never be shown.
    private let feed = [
        RemoteRelease(version: "0.4.0", body: "four oh"),
        RemoteRelease(version: "0.5.0", body: "beta", isPrerelease: true),
        RemoteRelease(version: "0.3.0", body: "three"),
        RemoteRelease(version: "0.4.1", body: "four one"),
        RemoteRelease(version: "0.4.2", body: "draft", isDraft: true),
        RemoteRelease(version: "0.2.1", body: "two one"),
    ]

    private func versions(_ r: [RemoteRelease]) -> [String] { r.map(\.version) }

    func testPublishableDropsDraftsAndPrereleasesAndSortsByVersion() {
        XCTAssertEqual(versions(ReleaseSpan.publishable(feed)),
                       ["0.4.1", "0.4.0", "0.3.0", "0.2.1"])
    }

    func testSortingIsByVersionNotByFeedOrder() {
        // GitHub returns newest-created first, which is usually the same thing and occasionally
        // is not: a patch on an old branch is published after a newer release.
        let outOfOrder = [RemoteRelease(version: "0.2.2", body: "late patch"),
                          RemoteRelease(version: "0.4.0", body: "four oh")]
        XCTAssertEqual(versions(ReleaseSpan.publishable(outOfOrder)), ["0.4.0", "0.2.2"])
    }

    // MARK: What you would gain by updating

    func testNewerThanTheRunningVersion() {
        XCTAssertEqual(versions(ReleaseSpan.newer(than: "0.3.0", in: feed)), ["0.4.1", "0.4.0"])
    }

    func testNothingIsNewerWhenYouAreOnTheLatest() {
        XCTAssertEqual(ReleaseSpan.newer(than: "0.4.1", in: feed), [])
    }

    func testAPrereleaseIsNeverOffered() {
        // 0.5.0 exists and is newer than everything, and must still not appear.
        XCTAssertFalse(versions(ReleaseSpan.newer(than: "0.4.1", in: feed)).contains("0.5.0"))
    }

    // MARK: What you just gained

    func testTheSpanCoversEveryReleaseYouSkipped() {
        // The case that started this: 0.3.0 straight to 0.4.1 has to show both 0.4.0 and 0.4.1,
        // because 0.4.0 is where the features were.
        XCTAssertEqual(versions(ReleaseSpan.between(from: "0.3.0", upToAndIncluding: "0.4.1", in: feed)),
                       ["0.4.1", "0.4.0"])
    }

    func testASingleStepShowsOneRelease() {
        XCTAssertEqual(versions(ReleaseSpan.between(from: "0.4.0", upToAndIncluding: "0.4.1", in: feed)),
                       ["0.4.1"])
    }

    func testTheSpanExcludesWhereYouCameFrom() {
        // You already read those notes on the version you were running.
        XCTAssertFalse(versions(ReleaseSpan.between(from: "0.3.0", upToAndIncluding: "0.4.1", in: feed))
                        .contains("0.3.0"))
    }

    func testTheSpanExcludesReleasesYouHaveNotInstalled() {
        // Up to *and including* what is running, never past it. 0.4.1 exists but you are on
        // 0.4.0, so its notes are not something you have just gained.
        XCTAssertEqual(versions(ReleaseSpan.between(from: "0.3.0", upToAndIncluding: "0.4.0", in: feed)),
                       ["0.4.0"])
    }

    func testNoRecordedOriginFallsBackToTheOneYouAreOn() {
        // A first install, or an upgrade from a build that never wrote the value. Claiming a
        // span would be inventing history, so it offers the release actually running.
        XCTAssertEqual(versions(ReleaseSpan.between(from: nil, upToAndIncluding: "0.4.1", in: feed)),
                       ["0.4.1"])
        XCTAssertEqual(versions(ReleaseSpan.between(from: "", upToAndIncluding: "0.4.1", in: feed)),
                       ["0.4.1"])
    }

    func testADowngradeDescribesWhatIsRunning() {
        // Rolled back to 0.3.0 from 0.4.1. Nothing was gained, and the honest thing to show is
        // the notes for the version now running rather than a backwards span.
        XCTAssertEqual(versions(ReleaseSpan.between(from: "0.4.1", upToAndIncluding: "0.3.0", in: feed)),
                       [])
    }

    func testAnUnknownRunningVersionYieldsNothingRatherThanEverything() {
        // A dev build reports "0", which is older than every release. The span up to it is
        // empty, which is right: it would otherwise claim the reader had gained all of them.
        XCTAssertEqual(ReleaseSpan.between(from: nil, upToAndIncluding: "0", in: feed), [])
    }
}

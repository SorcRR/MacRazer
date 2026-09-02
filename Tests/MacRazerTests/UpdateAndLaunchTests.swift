// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class AppLocationTests: XCTestCase {
    func testInstalledAppBundlesAreStable() {
        XCTAssertTrue(AppLocation.isStableInstall("/Applications/MacRazer.app"))
        XCTAssertTrue(AppLocation.isStableInstall("/Users/me/Applications/MacRazer.app"))
        XCTAssertTrue(AppLocation.isStableInstall("/Applications/MacRazer.app/"), "trailing slash")
    }

    func testRunningFromTheDiskImageIsNotAnInstall() {
        // The commonest case by far: launched straight out of the mounted DMG, never dragged
        // across. A login item recorded there points at nothing once the image is ejected.
        XCTAssertFalse(AppLocation.isStableInstall("/Volumes/MacRazer/MacRazer.app"))
    }

    func testTranslocatedAndTemporaryCopiesAreNotInstalls() {
        XCTAssertFalse(AppLocation.isStableInstall(
            "/private/var/folders/x1/T/AppTranslocation/AB-CD/d/MacRazer.app"))
        XCTAssertFalse(AppLocation.isStableInstall("/private/var/folders/x1/T/staging/MacRazer.app"))
        XCTAssertFalse(AppLocation.isStableInstall("/tmp/MacRazer.app"))
    }

    func testNonBundlePathsAreNotInstalls() {
        // `swift run`: Bundle.main is the SwiftPM binary's directory, not an .app.
        XCTAssertFalse(AppLocation.isStableInstall("/Users/me/proj/.build/release"))
        XCTAssertFalse(AppLocation.isStableInstall("/Applications/MacRazer.app/Contents/MacOS/MacRazer"))
        XCTAssertFalse(AppLocation.isStableInstall("MacRazer.app"), "relative path")
        XCTAssertFalse(AppLocation.isStableInstall(""))
    }
}

final class UpdatePayloadCheckTests: XCTestCase {
    private let id = "com.macrazer.menubar"

    private func reject(_ bundleID: String?, _ version: String?, current: String = "0.2.1")
        -> UpdatePayloadCheck.Rejection? {
        UpdatePayloadCheck.reject(
            payloadBundleID: bundleID, payloadVersion: version,
            expectedBundleID: id, currentVersion: current)
    }

    func testAcceptsANewerBuildOfTheSameApp() {
        XCTAssertNil(reject(id, "0.2.2"))
        XCTAssertNil(reject(id, "0.3.0"))
        XCTAssertNil(reject(id, "1.0.0"))
    }

    func testRejectsADifferentApp() {
        // The swap deletes the installed bundle, so anything that isn't demonstrably MacRazer
        // has to be refused — a mis-attached release asset must not overwrite the app.
        XCTAssertEqual(reject("com.example.other", "9.9.9"), .wrongApp)
    }

    func testRejectsAnUnreadablePayload() {
        // A missing Info.plist reads as nils; none of them may be waved through.
        XCTAssertEqual(reject(nil, nil), .wrongApp)
        XCTAssertEqual(reject(id, nil), .wrongApp)
        XCTAssertEqual(reject(id, ""), .wrongApp)
        XCTAssertEqual(
            UpdatePayloadCheck.reject(
                payloadBundleID: nil, payloadVersion: "0.3.0",
                expectedBundleID: nil, currentVersion: "0.2.1"),
            .wrongApp,
            "two unknowns must not match each other")
    }

    func testRejectsSameOrOlderVersions() {
        XCTAssertEqual(reject(id, "0.2.1"), .notNewer("0.2.1"))
        XCTAssertEqual(reject(id, "0.2.0"), .notNewer("0.2.0"))
        XCTAssertEqual(reject(id, "0.1.9"), .notNewer("0.1.9"))
    }

    func testVersionOrderingMatchesTheUpdateNotice() {
        // Same comparator as the "update available" badge, so the card can't offer an update
        // the installer then refuses.
        XCTAssertNil(reject(id, "0.2.10", current: "0.2.9"))
        XCTAssertEqual(reject(id, "0.2.9", current: "0.2.10"), .notNewer("0.2.9"))
    }
}

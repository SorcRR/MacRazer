// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import XCTest
@testable import MacRazer

/// LaunchServices calls the open completion on its own queue, so each test here calls back
/// from a background queue too and checks the result still lands on the main actor.
///
/// These can't reproduce the old trap itself. Swift only adds the runtime executor check to a
/// closure handed to an imported Objective-C API, not to a Swift function type like `Opener`.
/// The guard against that regression is `Completion` being `@Sendable`, which stops the
/// closure from inheriting main-actor isolation at compile time.
@MainActor
final class AppRelaunchTests: XCTestCase {
    private struct OpenFailed: Error {}

    private func relaunch(app: Bool, error: (any Error)?) async -> (launched: Bool, onMain: Bool) {
        await withCheckedContinuation { continuation in
            let opener: AppRelaunch.Opener = { _, config, completion in
                XCTAssertTrue(config.createsNewApplicationInstance)
                DispatchQueue.global().async {
                    completion(app ? NSRunningApplication.current : nil, error)
                }
            }
            AppRelaunch.openNewInstance(of: URL(fileURLWithPath: "/Applications/MacRazer.app"),
                                        opener: opener) { launched in
                continuation.resume(returning: (launched, Thread.isMainThread))
            }
        }
    }

    func testSuccessIsReportedOnTheMainActor() async {
        let result = await relaunch(app: true, error: nil)
        XCTAssertTrue(result.launched)
        XCTAssertTrue(result.onMain)
    }

    func testAnErrorMeansNotLaunched() async {
        let result = await relaunch(app: true, error: OpenFailed())
        XCTAssertFalse(result.launched)
        XCTAssertTrue(result.onMain)
    }

    func testNoAppMeansNotLaunched() async {
        let result = await relaunch(app: false, error: nil)
        XCTAssertFalse(result.launched)
    }
}

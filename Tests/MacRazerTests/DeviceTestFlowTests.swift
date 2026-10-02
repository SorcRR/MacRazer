// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The order of the test window's screens, and the relaunch that resumes it.
final class DeviceTestFlowTests: XCTestCase {
    typealias Stage = DeviceTestModel.Stage

    func testNextWalksEveryStepToReview() {
        var stage = Stage.identify
        var seen = [stage]
        while let next = DeviceTestFlow.next(from: stage) { stage = next; seen.append(stage) }
        XCTAssertEqual(seen, [.identify, .battery, .dpi, .polling, .lighting, .buttons, .review])
    }

    func testBackUndoesNext() {
        for stage in [Stage.identify, .battery, .dpi, .polling, .lighting, .buttons] {
            let next = DeviceTestFlow.next(from: stage)!
            XCTAssertEqual(DeviceTestFlow.back(from: next, identifyRan: true), stage, "\(stage)")
        }
    }

    func testReviewWithoutAnyStepsHasNothingToGoBackTo() {
        // Without Input Monitoring the test goes straight to Review.
        XCTAssertNil(DeviceTestFlow.back(from: .review, identifyRan: false))
        XCTAssertNil(DeviceTestFlow.back(from: .identify, identifyRan: true))
        XCTAssertNil(DeviceTestFlow.next(from: .review))
        XCTAssertNil(DeviceTestFlow.next(from: .intro), "Start, not Next, leaves the intro")
    }

    // MARK: Resume after relaunch

    private func defaults() -> UserDefaults {
        let name = "DeviceTestFlowTests.\(UUID())"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testAFreshRelaunchResumesOnce() {
        let d = defaults(), now = Date()
        d.set(now.addingTimeInterval(-5), forKey: DeviceTestModel.resumeKey)
        XCTAssertTrue(DeviceTestModel.takeResumeRequest(d, now: now))
        XCTAssertFalse(DeviceTestModel.takeResumeRequest(d, now: now), "used up")
    }

    func testAStaleOrMissingRequestIsIgnoredAndCleared() {
        let d = defaults(), now = Date()
        XCTAssertFalse(DeviceTestModel.takeResumeRequest(d, now: now))
        d.set(now.addingTimeInterval(-DeviceTestModel.resumeWindow - 1), forKey: DeviceTestModel.resumeKey)
        XCTAssertFalse(DeviceTestModel.takeResumeRequest(d, now: now), "a relaunch that failed, days ago")
        XCTAssertNil(d.object(forKey: DeviceTestModel.resumeKey))
        d.set(true, forKey: DeviceTestModel.resumeKey)
        XCTAssertFalse(DeviceTestModel.takeResumeRequest(d, now: now), "the old flag from a dev build")
    }
}

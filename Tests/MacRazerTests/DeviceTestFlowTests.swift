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

    /// The Bluetooth test is one screen, then Review, with no USB steps behind it.
    func testTheBluetoothTestGoesStraightToReview() {
        XCTAssertEqual(DeviceTestFlow.next(from: .bluetooth), .review)
        XCTAssertNil(DeviceTestFlow.back(from: .bluetooth, identifyRan: false))
    }

    // MARK: Testing only what's missing

    /// A run limited to polling goes Identify, Polling, Review, and back the same way.
    func testAFocusedRunVisitsOnlyItsSteps() {
        let skipping = DeviceTestFlow.skipped(focus: [.polling])
        XCTAssertEqual(skipping, [.battery, .dpi, .lighting, .buttons])
        var stage = Stage.identify
        var seen = [stage]
        while let next = DeviceTestFlow.next(from: stage, skipping: skipping) { stage = next; seen.append(stage) }
        XCTAssertEqual(seen, [.identify, .polling, .review])
        XCTAssertEqual(DeviceTestFlow.back(from: .review, identifyRan: true, skipping: skipping), .polling)
        XCTAssertEqual(DeviceTestFlow.back(from: .polling, identifyRan: true, skipping: skipping), .identify)
    }

    func testTheFullTestSkipsNothing() {
        XCTAssertEqual(DeviceTestFlow.skipped(focus: nil), [])
        XCTAssertEqual(DeviceTestFlow.next(from: .battery, skipping: []), .dpi)
    }

    /// Skip asks first only on a step whose data the registry still lacks.
    func testSkipAsksFirstOnlyOnAMissingStep() {
        XCTAssertTrue(DeviceTestFlow.skipNeedsConfirming(.polling, missing: [.polling]))
        XCTAssertFalse(DeviceTestFlow.skipNeedsConfirming(.dpi, missing: [.polling]), "already verified")
        XCTAssertFalse(DeviceTestFlow.skipNeedsConfirming(.lighting, missing: []), "fully supported")
        XCTAssertTrue(DeviceTestFlow.skipNeedsConfirming(.lighting, missing: RazerFeature.allCases), "a new mouse")
        XCTAssertFalse(DeviceTestFlow.skipNeedsConfirming(.buttons, missing: RazerFeature.allCases),
                       "the button step is information only")
    }

    /// What Skip asks about comes from the registry: a row's unverified steps, or every step
    /// for a mouse not on record.
    @MainActor func testMissingFeaturesFollowTheRegistry() {
        func missing(_ pid: Int?) -> [RazerFeature] {
            let model = DeviceTestModel(controller: MouseController(), permissions: PermissionsModel(), reportEndpoint: nil)
            if let pid { model.loadPreview(.intro, pid: pid, ranSteps: false) }
            return model.missingFeatures
        }
        XCTAssertEqual(missing(0x00DB), [], "Cobra HyperSpeed")
        XCTAssertEqual(missing(0x0053), [.lighting], "Naga Chroma")
        XCTAssertEqual(missing(0x00E3), [], "Basilisk V4 Pro: polling unverified, but it refuses the classic command")
        XCTAssertEqual(missing(0x7FFF), RazerFeature.allCases, "not on record")
        XCTAssertEqual(missing(nil), RazerFeature.allCases, "no mouse connected")
    }

    func testEachFeatureStepMapsBack() {
        for feature in RazerFeature.allCases {
            XCTAssertEqual(DeviceTestFlow.feature(for: DeviceTestFlow.stage(for: feature)), feature)
        }
        XCTAssertNil(DeviceTestFlow.feature(for: .buttons))
    }

    func testTheSkipQuestionNamesTheStep() {
        XCTAssertTrue(DeviceTestView.skipMessage(for: RazerFeature.polling).hasPrefix("We don't have polling rate data"))
        XCTAssertTrue(DeviceTestView.skipMessage(for: RazerFeature.dpi).hasPrefix("We don't have DPI data"))
        XCTAssertTrue(DeviceTestView.skipMessage(for: RazerFeature.lighting).hasPrefix("We don't have lighting data"))
    }

    /// Which intro each kind of mouse gets, from the registry.
    @MainActor func testTheIntroFollowsTheRegistry() {
        func support(_ pid: Int) -> DeviceTestModel.Support {
            let model = DeviceTestModel(controller: MouseController(), permissions: PermissionsModel(), reportEndpoint: nil)
            model.loadPreview(.intro, pid: pid, ranSteps: false)
            return model.support
        }
        XCTAssertEqual(support(0x00DB), .full, "Cobra HyperSpeed")
        XCTAssertEqual(support(0x00E3), .partly(works: [.battery, .dpi, .lighting], missing: [.polling]), "Basilisk V4 Pro")
        XCTAssertEqual(support(0x0053), .partly(works: [.dpi, .polling], missing: [.lighting]), "Naga Chroma")
        XCTAssertEqual(support(0x0034), .partly(works: [.dpi, .polling], missing: [.lighting]), "Taipan")
        XCTAssertEqual(support(0x008F), .full, "Naga Pro (Wired)")
        XCTAssertEqual(support(0x006E), .unknown, "DeathAdder Essential (2018): on record, but nothing shown working yet")
        XCTAssertEqual(support(0x9999), .unknown)
    }

    /// A focused run keeps steps it passed over apart from ones the person skipped, and its
    /// thank-you doesn't call the report partial for them.
    func testAFocusedRunsThankYou() {
        let leftOut = ["Battery", "DPI", "Lighting"]
        let passed = DeviceTestVerdict.make(knownFullySupported: false, steps: [
            ("Identify", .passed), ("Battery", .skipped), ("DPI", .skipped), ("Polling rate", .passed), ("Lighting", .skipped),
        ])
        XCTAssertTrue(DeviceTestVerdict.focusedThankYou(passed, leftOut: leftOut).hasPrefix("Everything that was still missing worked"))
        let failed = DeviceTestVerdict.make(knownFullySupported: false, steps: [
            ("Identify", .passed), ("Battery", .skipped), ("DPI", .skipped), ("Polling rate", .failed), ("Lighting", .skipped),
        ])
        XCTAssertTrue(DeviceTestVerdict.focusedThankYou(failed, leftOut: leftOut).hasPrefix("Polling rate still didn't work"))
        let skipped = DeviceTestVerdict.make(knownFullySupported: false, steps: [
            ("Identify", .passed), ("Battery", .skipped), ("DPI", .skipped), ("Polling rate", .skipped), ("Lighting", .skipped),
        ])
        XCTAssertTrue(DeviceTestVerdict.focusedThankYou(skipped, leftOut: leftOut).hasPrefix("Some steps were skipped"))
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

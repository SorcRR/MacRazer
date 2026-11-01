// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class SliderScrollTests: XCTestCase {
    private let dpi = 100.0...26000.0
    private let percent = 0.0...100.0

    // MARK: How far a notch goes

    func testANotchIsOnePercentOfTheRange() {
        XCTAssertEqual(SliderScroll.notch(range: percent, snap: 1), 1, "brightness")
        XCTAssertEqual(SliderScroll.notch(range: 0...1, snap: 0), 0.01, accuracy: 1e-12, "wave speed")
        XCTAssertEqual(SliderScroll.notch(range: dpi, snap: 50), 250, "1% of 25,900 on the 50 grid")
        XCTAssertEqual(SliderScroll.notch(range: 100...30000, snap: 50), 300)
    }

    /// The sleep timer's 1% is 8.4 s, finer than the 15 s it can be set in.
    func testANotchIsNeverFinerThanTheSlidersOwnStep() {
        XCTAssertEqual(SliderScroll.notch(range: 60...900, snap: 15), 15)
    }

    // MARK: Wheel

    func testAWheelNotchMovesOneNotchEitherWay() {
        XCTAssertEqual(SliderScroll.notched(40, delta: 1, range: percent, notch: 1, snap: 1), 41)
        XCTAssertEqual(SliderScroll.notched(40, delta: -1, range: percent, notch: 1, snap: 1), 39)
        XCTAssertEqual(SliderScroll.notched(1500, delta: 1, range: dpi, notch: 250, snap: 50), 1750)
    }

    /// Acceleration makes a fast flick report a bigger delta; a notch still moves one notch.
    func testAFlickedNotchIsStillOneNotch() {
        XCTAssertEqual(SliderScroll.notched(50, delta: 9, range: percent, notch: 1, snap: 1), 51)
    }

    /// A DPI typed off the grid lands back on it.
    func testLandsOnTheSlidersGrid() {
        XCTAssertEqual(SliderScroll.notched(1630, delta: 1, range: dpi, notch: 250, snap: 50), 1900)
    }

    func testStaysInRange() {
        XCTAssertEqual(SliderScroll.notched(100, delta: -1, range: dpi, notch: 250, snap: 50), 100)
        XCTAssertEqual(SliderScroll.notched(26000, delta: 1, range: dpi, notch: 250, snap: 50), 26000)
        XCTAssertEqual(SliderScroll.notched(100, delta: 1, range: percent, notch: 1, snap: 1), 100)
    }

    func testNoDeltaChangesNothing() {
        XCTAssertEqual(SliderScroll.notched(42, delta: 0, range: percent, notch: 1, snap: 1), 42)
    }

    func testUnsnappedSlidersMoveExactly() {
        XCTAssertEqual(SliderScroll.notched(0.5, delta: 1, range: 0...1, notch: 0.01, snap: 0), 0.51, accuracy: 1e-9)
    }

    // MARK: Trackpad

    /// Runs a swipe as a stream of small trackpad events.
    private func swipe(from start: Double, events: Int, pointsEach: Double) -> Double {
        var value = start, carried = 0.0
        for _ in 0..<events {
            (value, carried) = SliderScroll.swiped(value, delta: pointsEach, carried: carried, range: percent,
                                                   notch: 1, snap: 1)
        }
        return value
    }

    /// 60 events of 2 pt is 120 pt, 40% of `pointsPerSpan`: brightness moves 40, however split.
    func testASwipeMovesInProportionHoweverItIsSplit() {
        XCTAssertEqual(swipe(from: 20, events: 60, pointsEach: 2), 60)
        XCTAssertEqual(swipe(from: 20, events: 1, pointsEach: 120), 60)
        XCTAssertEqual(swipe(from: 60, events: 60, pointsEach: -2), 20)
    }

    func testASlowSwipeAddsUpToANotch() {
        // 3 pt per 1% notch: the first two events carry, the third moves.
        var r = SliderScroll.swiped(50, delta: 1, carried: 0, range: percent, notch: 1, snap: 1)
        XCTAssertEqual(r.value, 50)
        r = SliderScroll.swiped(r.value, delta: 1, carried: r.carried, range: percent, notch: 1, snap: 1)
        XCTAssertEqual(r.value, 50)
        r = SliderScroll.swiped(r.value, delta: 1, carried: r.carried, range: percent, notch: 1, snap: 1)
        XCTAssertEqual(r.value, 51)
    }

    func testASwipePastTheEndStopsThereAndTurnsBackAtOnce() {
        XCTAssertEqual(SliderScroll.swiped(98, delta: 300, carried: 0, range: percent, notch: 1, snap: 1).value, 100)
        let atEnd = SliderScroll.swiped(100, delta: 300, carried: 0, range: percent, notch: 1, snap: 1)
        XCTAssertEqual(atEnd.carried, 0, "nothing banked against the end")
        XCTAssertEqual(SliderScroll.swiped(100, delta: -3, carried: atEnd.carried, range: percent,
                                           notch: 1, snap: 1).value, 99)
    }
}

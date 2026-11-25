// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The rules that turn one hold of a gesture button into a swipe or a click. The tap feeds
/// every drag to the recognizer, so a swipe that fires twice, the wrong way, or not at all
/// would be felt on every use.
final class GestureRecognizerTests: XCTestCase {
    private let threshold = GestureRecognizer.threshold

    /// Each direction fires its own swipe. CGEvent deltas grow downward, so a negative y is
    /// up: getting that backwards would swap Mission Control and App Exposé.
    func testEachDirectionFiresItsOwnSwipe() {
        let moves: [(dx: Double, dy: Double, expected: GestureDirection)] = [
            (0, -threshold, .up), (0, threshold, .down), (-threshold, 0, .left), (threshold, 0, .right),
        ]
        for move in moves {
            var recognizer = GestureRecognizer()
            XCTAssertEqual(recognizer.move(dx: move.dx, dy: move.dy), move.expected,
                           "(\(move.dx), \(move.dy)) should be \(move.expected)")
        }
    }

    /// A hand never moves along one axis only: the larger of the two decides.
    func testTheDominantAxisDecides() {
        var mostlyRight = GestureRecognizer()
        XCTAssertEqual(mostlyRight.move(dx: 55, dy: 30), .right, "a swipe right that drifts down")
        var mostlyUp = GestureRecognizer()
        XCTAssertEqual(mostlyUp.move(dx: -20, dy: -70), .up, "a swipe up that drifts left")
    }

    /// The drift of a press and release in place must stay a click.
    func testMovementBelowTheThresholdIsAClick() {
        var recognizer = GestureRecognizer()
        XCTAssertNil(recognizer.move(dx: 30, dy: 20))
        XCTAssertNil(recognizer.move(dx: 10, dy: -5))
        XCTAssertTrue(recognizer.end(), "nothing fired, so the release is a click")
    }

    /// Exactly the threshold is far enough, so a swipe doesn't need one point more than the
    /// constant says.
    func testExactlyTheThresholdFires() {
        var recognizer = GestureRecognizer()
        XCTAssertNil(recognizer.move(dx: 0, dy: threshold.nextDown))
        var exact = GestureRecognizer()
        XCTAssertEqual(exact.move(dx: 0, dy: threshold), .down)
    }

    /// One swipe per hold: a long swipe, or turning a corner, must not open Mission Control
    /// and then change Space too. And a hold that swiped is not also a click.
    func testOnlyOneSwipeFiresPerHold() {
        var recognizer = GestureRecognizer()
        XCTAssertEqual(recognizer.move(dx: 60, dy: 0), .right)
        XCTAssertNil(recognizer.move(dx: 60, dy: 0), "further along the same way")
        XCTAssertNil(recognizer.move(dx: 0, dy: -300), "a turn into another direction")
        XCTAssertEqual(recognizer.fired, .right)
        XCTAssertFalse(recognizer.end(), "a hold that swiped is not a click")
    }

    /// The tap delivers movement a few points at a time, at the mouse's polling rate: the
    /// recognizer has to add them up, and fire the moment the sum gets there.
    func testManySmallMovementsAddUp() {
        var recognizer = GestureRecognizer()
        var fired: [(step: Int, direction: GestureDirection)] = []
        for step in 1...150 {
            if let direction = recognizer.move(dx: -0.5, dy: 0.1) { fired.append((step, direction)) }
        }
        XCTAssertEqual(fired.map(\.direction), [.left], "fired once, to the left")
        XCTAssertEqual(fired.first?.step, 100, "at 100 × 0.5 = 50 points, not before and not at release")
    }

    /// Net movement, not distance travelled: out and back is a press in place.
    func testGoingThereAndBackIsAClick() {
        var recognizer = GestureRecognizer()
        XCTAssertNil(recognizer.move(dx: 40, dy: 0))
        XCTAssertNil(recognizer.move(dx: -40, dy: 0))
        XCTAssertTrue(recognizer.end())
    }

    /// `end` starts over, so the hold state can keep one recognizer for the next hold.
    func testEndingStartsANewHold() {
        var recognizer = GestureRecognizer()
        XCTAssertEqual(recognizer.move(dx: 0, dy: 80), .down)
        XCTAssertFalse(recognizer.end())
        XCTAssertEqual(recognizer, GestureRecognizer(), "back to a fresh hold")
        XCTAssertEqual(recognizer.move(dx: 0, dy: -80), .up, "the next hold swipes again")
    }
}

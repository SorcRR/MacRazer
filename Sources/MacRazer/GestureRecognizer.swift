// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

/// Which way the pointer went while a gesture button was held.
enum GestureDirection: CaseIterable, Sendable {
    case up, down, left, right
}

/// Turns the pointer movement of one gesture-button hold into at most one swipe. Pure and
/// O(1) per event, so the tap can feed it every drag at the mouse's polling rate and the
/// rules are tested without one.
///
/// The swipe fires as soon as the movement is far enough, not at release: Mission Control
/// opening while the hand is still moving is what makes it feel like a gesture. Only one per
/// hold, so a long swipe doesn't fire again and again.
struct GestureRecognizer: Equatable, Sendable {
    /// How far, in points, the pointer must go along one axis. Enough that the small drift of
    /// a press and release doesn't count, short enough for a flick of the wrist.
    static let threshold: Double = 50

    /// The net movement since the hold began. Net rather than travelled: going right and then
    /// back left again adds up to nothing, which is still a click.
    private(set) var dx: Double = 0
    private(set) var dy: Double = 0
    /// The swipe this hold fired, if any.
    private(set) var fired: GestureDirection?

    /// Adds a movement (CGEvent deltas: y grows downward) and returns the direction the first
    /// time the net movement along the dominant axis reaches `threshold`. Nil otherwise,
    /// including every movement after the swipe has fired.
    mutating func move(dx: Double, dy: Double) -> GestureDirection? {
        guard fired == nil else { return nil }
        self.dx += dx
        self.dy += dy
        let horizontal = abs(self.dx), vertical = abs(self.dy)
        guard max(horizontal, vertical) >= Self.threshold else { return nil }
        // An exact diagonal goes to the horizontal swipe, so the answer never depends on
        // which delta arrived last.
        let direction: GestureDirection = horizontal >= vertical
            ? (self.dx > 0 ? .right : .left)
            : (self.dy > 0 ? .down : .up)
        fired = direction
        return direction
    }

    /// The button came back up. Returns whether the hold was a click (no swipe fired) and
    /// starts over, so the same value can follow the next hold.
    mutating func end() -> Bool {
        defer { self = GestureRecognizer() }
        return fired == nil
    }
}

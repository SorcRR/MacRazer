// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The bookkeeping that lets a tap preempt a background read.
///
/// Everything the app says to the mouse goes through one serial queue. Opening the popover
/// issues several round-trips, each with a receiver wait, so a tap arriving a moment later
/// used to wait them out. Reads now stand down while a user command is pending, which only
/// works if "pending" is raised before the command reaches the queue and always comes back
/// down afterwards.
final class UserCommandPriorityTests: XCTestCase {
    func testPendingIsRaisedBeforeTheCommandReachesTheQueue() {
        let controller = MouseController()
        XCTAssertFalse(controller.userWorkPendingForTesting)

        controller.runUserCommandForTesting { Thread.sleep(forTimeInterval: 0.05) }

        // Synchronously true on return, which is the whole point: a read already running on
        // the queue has to be able to see it and stop.
        XCTAssertTrue(controller.userWorkPendingForTesting,
                      "a read already in flight cannot stand down for something it cannot see")
    }

    func testPendingComesBackDown() {
        let controller = MouseController()
        for _ in 0..<5 { controller.runUserCommandForTesting {} }

        let deadline = Date().addingTimeInterval(2)
        while controller.userWorkPendingForTesting, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(controller.userWorkPendingForTesting,
                       "a stuck count stops every background read for the life of the process")
    }
}

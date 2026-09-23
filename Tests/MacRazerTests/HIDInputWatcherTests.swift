// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The reports themselves need a real mouse, so what is pinned here is the bookkeeping around
/// them: whether the watcher believes it is listening, and whether a later start can try
/// again. That matters because the watcher is started from every offline poll and stopped
/// once the mouse answers, and a watcher that thinks it is running when nothing is open would
/// swallow every one of those starts.
///
/// A vendor id nothing matches keeps this the same here and on CI, where no mouse is plugged
/// in at all.
final class HIDInputWatcherTests: XCTestCase {
    private let noSuchVendor = 0xFFFF

    private func watcher(onInput: @escaping @Sendable () -> Void = { XCTFail("nothing should report") })
        -> HIDInputWatcher {
        HIDInputWatcher(vendorId: noSuchVendor, onInput: onInput)
    }

    func testAWatcherThatOpenedNothingIsNotRunning() {
        // The bug this exists for: marking itself running before knowing whether any device
        // opened. Every later start then returned at the guard, and the watcher sat there
        // listening to nothing for the rest of the time the mouse was away.
        let w = watcher()
        w.start()
        XCTAssertFalse(w.isRunning, "no device opened, so nothing is being listened to")
    }

    func testStartCanBeRetried() {
        // Offline polls call start() again and again. A mouse whose interfaces were missing
        // the first time (dongle out, or Input Monitoring not granted yet) has to be picked
        // up by one of those later attempts.
        let w = watcher()
        for _ in 0..<3 {
            w.start()
            XCTAssertFalse(w.isRunning)
        }
    }

    func testStopIsSafeWhenNothingWasStarted() {
        let w = watcher()
        w.stop()
        w.stop()
        XCTAssertFalse(w.isRunning)
    }
}

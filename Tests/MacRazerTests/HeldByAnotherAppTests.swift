// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import IOKit
import XCTest
@testable import MacRazer

/// #139: another app held a wired Lancehead exclusively, and the popover only said Offline.
final class HeldByAnotherAppTests: XCTestCase {
    private func text(_ error: HIDDevice.HIDError) -> String { String(describing: error) }

    func testAnExclusiveOpenOrWriteReadsAsHeldByAnotherApp() {
        XCTAssertTrue(HIDDevice.errorLooksHeldByAnotherApp(text(.openFailed(kIOReturnExclusiveAccess))))
        XCTAssertTrue(HIDDevice.errorLooksHeldByAnotherApp(text(.setReportFailed(kIOReturnExclusiveAccess))))
        XCTAssertTrue(HIDDevice.errorLooksHeldByAnotherApp(text(.getReportFailed(kIOReturnExclusiveAccess))))
        // The exact line from the #139 log.
        XCTAssertTrue(HIDDevice.errorLooksHeldByAnotherApp("IOHIDDeviceOpen failed: 0xe00002c5"))
    }

    func testOtherFailuresDoNot() {
        XCTAssertFalse(HIDDevice.errorLooksHeldByAnotherApp(text(.openFailed(kIOReturnNotPermitted))))
        XCTAssertFalse(HIDDevice.errorLooksHeldByAnotherApp(text(.timeout)))
        XCTAssertFalse(HIDDevice.errorLooksHeldByAnotherApp(text(.notFound)))
        XCTAssertFalse(HIDDevice.errorLooksPermissionDenied(text(.openFailed(kIOReturnExclusiveAccess))))
    }
}

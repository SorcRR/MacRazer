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

    func testTheTypedCheckReadsTheCode() {
        XCTAssertTrue(HIDDevice.isHeldByAnotherApp(HIDDevice.HIDError.openFailed(kIOReturnExclusiveAccess)))
        XCTAssertTrue(HIDDevice.isHeldByAnotherApp(HIDDevice.HIDError.setReportFailed(kIOReturnExclusiveAccess)))
        XCTAssertFalse(HIDDevice.isHeldByAnotherApp(HIDDevice.HIDError.openFailed(kIOReturnNotPermitted)))
        XCTAssertFalse(HIDDevice.isHeldByAnotherApp(HIDDevice.HIDError.timeout))
        XCTAssertFalse(HIDDevice.isHeldByAnotherApp(CocoaError(.fileNoSuchFile)))
    }

    // MARK: Popover

    func testAHeldMouseGetsTheCardAndTheSubtitle() {
        XCTAssertEqual(PopoverStatus.notice(connected: false, onBluetooth: false, held: true, noMouse: false),
                       .heldByAnotherApp)
        XCTAssertEqual(subtitle(held: true, deviceKnown: true), "In use by another app")
    }

    func testHeldFromLaunchStillSaysSo() {
        // Never opened, so no name: the no-mouse card carries the advice, and the header agrees.
        XCTAssertNil(PopoverStatus.notice(connected: false, onBluetooth: false, held: true, noMouse: true))
        XCTAssertEqual(subtitle(held: true, deviceKnown: false), "In use by another app")
    }

    func testOtherStatesAreUnchanged() {
        XCTAssertNil(PopoverStatus.notice(connected: true, onBluetooth: false, held: true, noMouse: false))
        XCTAssertEqual(PopoverStatus.notice(connected: false, onBluetooth: true, held: true, noMouse: false), .bluetooth)
        XCTAssertNil(PopoverStatus.notice(connected: false, onBluetooth: false, held: false, noMouse: false))
        XCTAssertEqual(subtitle(held: false, deviceKnown: true), "Offline")
        XCTAssertEqual(subtitle(held: false, deviceKnown: false), "Connect a Razer mouse")
        XCTAssertEqual(subtitle(connected: true, held: true, deviceKnown: true), "Connected")
    }

    private func subtitle(connected: Bool = false, held: Bool, deviceKnown: Bool) -> String {
        PopoverStatus.headerSubtitle(connected: connected, supported: true, reconnecting: false, onBluetooth: false,
                                     deviceKnown: deviceKnown, held: held)
    }

    // MARK: Device test

    func testAStepThatLostTheMouseToAnotherAppIsCaught() {
        let held = String(describing: HIDDevice.HIDError.setReportFailed(kIOReturnExclusiveAccess))
        XCTAssertTrue(DeviceTestModel.heldByAnotherApp(nil, [exchange(nil), exchange(held)]))
        XCTAssertTrue(DeviceTestModel.heldByAnotherApp(held, []))
    }

    func testOrdinaryStepFailuresAreKept() {
        let refused = String(describing: HIDDevice.HIDError.commandFailed)
        XCTAssertFalse(DeviceTestModel.heldByAnotherApp(refused, [exchange(refused), exchange(nil)]))
        XCTAssertFalse(DeviceTestModel.heldByAnotherApp(nil, []))
    }

    private func exchange(_ error: String?) -> RecordingChannel.Exchange {
        RecordingChannel.Exchange(commandClass: 0x04, commandId: 0x85, transactionId: nil, status: error == nil ? 2 : nil,
                                  response: [], error: error, milliseconds: 30)
    }
}

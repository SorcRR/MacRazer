// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CoreBluetooth
import IOKit.hid
import XCTest
@testable import MacRazer

/// The gesture trace (`GestureDebugLog`): what it may log of a HID report, which devices it
/// watches, and what it sends over Bluetooth.
final class GestureDebugTraceTests: XCTestCase {
    private func line(_ id: Int, _ bytes: [UInt8]) -> String? {
        GestureDebugReportFilter.line(reportID: id, bytes: bytes)
    }

    // MARK: Report filter

    func testPointerReportsAreNeverLogged() {
        XCTAssertNil(line(1, [0x01, 0x00, 0x05, 0x00, 0xFB, 0xFF, 0x00, 0x00, 0x00]))
        XCTAssertNil(line(0, [0x00, 0x05, 0xFB, 0x00]), "a device without report ids")
    }

    func testPrivateKeyAndNotificationReportsAreLoggedWhole() {
        XCTAssertEqual(line(4, [0x04, 0x52, 0, 0, 0, 0, 0, 0, 0]), "HIDREPORT id=4 len=9 04 52 00 00 00 00 00 00 00")
        XCTAssertEqual(line(5, [0x05, 0x05, 0x02, 0x03, 0x84, 0x03, 0x84, 0, 0]),
                       "HIDREPORT id=5 len=9 05 05 02 03 84 03 84 00 00")
    }

    func testKeyboardReportIsLoggedOnlyForF13ToF20() {
        XCTAssertEqual(line(6, [0x06, 0x00, 0x00, 0x6F, 0, 0, 0, 0, 0]), "HIDREPORT id=6 len=9 06 00 00 6f 00 00 00 00 00")
        XCTAssertEqual(line(6, [0x06, 0, 0, 0, 0, 0, 0, 0, 0]), "HIDREPORT id=6 len=9 06 00 00 00 00 00 00 00 00",
                       "a release says nothing typed")
        XCTAssertEqual(line(6, [0x06, 0x00, 0x00, 0x68, 0x6F, 0, 0, 0, 0])?.hasPrefix("HIDREPORT id=6 len=9"), true)
        XCTAssertEqual(line(6, [0x06, 0x00, 0x00, 0x04, 0, 0, 0, 0, 0]), "HIDREPORT id=6 (not recorded)")
        XCTAssertEqual(line(6, [0x06, 0x00, 0x00, 0x6F, 0x04, 0, 0, 0, 0]), "HIDREPORT id=6 (not recorded)",
                       "F20 alongside another key")
        XCTAssertEqual(line(6, [0x06, 0x08, 0x00, 0x6F, 0, 0, 0, 0, 0]), "HIDREPORT id=6 (not recorded)",
                       "a modifier held with it")
    }

    func testNoOtherKeyboardUsageEverReachesTheLog() {
        for usage in UInt8.min...UInt8.max where usage != 0 && !(0x68...0x6F).contains(usage) {
            for position in 1...8 {
                var report = [UInt8](repeating: 0, count: 9)
                report[0] = 0x06
                report[position] = usage
                XCTAssertEqual(line(6, report), "HIDREPORT id=6 (not recorded)", "usage \(usage) at \(position)")
            }
        }
    }

    func testKeyboardIDsFromTheDescriptorAreFilteredToo() {
        XCTAssertEqual(GestureDebugReportFilter.line(reportID: 2, bytes: [0x02, 0x00, 0x00, 0x15, 0, 0, 0, 0],
                                                     keyboard: [2, 6]),
                       "HIDREPORT id=2 (not recorded)")
        XCTAssertNil(GestureDebugReportFilter.line(reportID: 3, bytes: [0x03, 0x01], pointer: [0, 1, 3]))
    }

    func testRateLimitMutesAStreamingReportAndSaysHowManyWentUnlogged() {
        var rate = GestureDebugReportFilter.RateLimit()
        let cap = GestureDebugReportFilter.RateLimit.perSecond
        let verdicts = (0..<(cap + 5)).map { _ in rate.admit(reportID: 5, at: 100.2) }
        XCTAssertEqual(verdicts.filter(\.log).count, cap)
        XCTAssertTrue(rate.admit(reportID: 4, at: 100.3).log, "each id has its own budget")
        let next = rate.admit(reportID: 5, at: 101.0)
        XCTAssertTrue(next.log)
        XCTAssertEqual(next.droppedBefore, 5)
        XCTAssertEqual(rate.admit(reportID: 5, at: 101.1).droppedBefore, 0)
    }

    // MARK: Which devices

    func testWatchesRazerMiceAndNeverAKeyboard() {
        let gd = kHIDPage_GenericDesktop
        // The Cobra HyperSpeed over Bluetooth, and on its dongle.
        XCTAssertTrue(GestureDebugHIDWatch.watches(vendorID: 0x068E, productID: 0x00DC, primaryUsagePage: gd, primaryUsage: kHIDUsage_GD_Mouse))
        XCTAssertTrue(GestureDebugHIDWatch.watches(vendorID: 0x068E, productID: 0x00DC, primaryUsagePage: kHIDPage_Consumer, primaryUsage: 1),
                      "a known Bluetooth mouse whatever its first collection")
        XCTAssertTrue(GestureDebugHIDWatch.watches(vendorID: 0x1532, productID: 0x00DB, primaryUsagePage: gd, primaryUsage: kHIDUsage_GD_Mouse))
        // Its dongle's keyboard interface, and a keyboard over Bluetooth.
        XCTAssertFalse(GestureDebugHIDWatch.watches(vendorID: 0x1532, productID: 0x00DB, primaryUsagePage: gd, primaryUsage: kHIDUsage_GD_Keyboard))
        XCTAssertFalse(GestureDebugHIDWatch.watches(vendorID: 0x068E, productID: 0x00DC, primaryUsagePage: gd, primaryUsage: kHIDUsage_GD_Keyboard))
        XCTAssertFalse(GestureDebugHIDWatch.watches(vendorID: 0x068E, productID: 0x02C3, primaryUsagePage: gd, primaryUsage: kHIDUsage_GD_Keyboard))
        XCTAssertFalse(GestureDebugHIDWatch.watches(vendorID: 0x068E, productID: 0x00DC, primaryUsagePage: kHIDPage_KeyboardOrKeypad, primaryUsage: 0))
        // A Razer keyboard on USB, whichever interface: 0x026B, and one the accessories list.
        for usage in [kHIDUsage_GD_Keyboard, kHIDUsage_GD_Keypad, kHIDUsage_GD_Mouse] {
            XCTAssertFalse(GestureDebugHIDWatch.watches(vendorID: 0x1532, productID: 0x026B, primaryUsagePage: gd, primaryUsage: usage))
            XCTAssertFalse(GestureDebugHIDWatch.watches(vendorID: 0x1532, productID: 0x022A, primaryUsagePage: gd, primaryUsage: usage))
        }
        XCTAssertFalse(GestureDebugHIDWatch.watches(vendorID: 0x046D, productID: 0xC52B, primaryUsagePage: gd, primaryUsage: kHIDUsage_GD_Mouse))
    }

    // MARK: Bluetooth probes

    /// The trace's probes only read: the device mode is MacRazer's own to write, and nothing
    /// the trace sends can change it.
    func testProbesOnlyRead() {
        for key in BLEProtocol.traceProbeKeys {
            XCTAssertTrue(key.isRead, "\(key.bytes)")
            XCTAssertNotNil(BLEProtocol.traceReadRequest(key), "\(key.bytes)")
        }
        XCTAssertFalse(BLEProtocol.traceProbeKeys.contains(.deviceModeSet))
    }

    // MARK: Lines

    func testReplyLineShowsStatusHeaderAndPayload() {
        var reply = BLEProtocol.TraceAssembler(id: 0x30)
        XCTAssertEqual(GestureDebugLog.describe(reply, timedOut: true), "timeout, no reply")
        reply.add(Data([0x30, 0x00, 0, 0, 0, 0, 0, 0x03]))
        reply.add(Data([0x30, 0x02, 0, 0, 0, 0, 0, 0x02]))
        reply.add(Data([0x03, 0x00]))
        XCTAssertEqual(GestureDebugLog.describe(reply, timedOut: false),
                       "status=02 (after 03) len=2 hdr=30 02 00 00 00 00 00 02: 03 00")
        var partial = BLEProtocol.TraceAssembler(id: 0x31)
        partial.add(Data([0x31, 0x24, 0, 0, 0, 0, 0, 0x02]))
        partial.add(Data([0x04, 0x05]))
        XCTAssertEqual(GestureDebugLog.describe(partial, timedOut: true),
                       "timeout status=02 len=36 got=2 hdr=31 24 00 00 00 00 00 02: 04 05")
    }

    func testCharacteristicPropertiesByName() {
        XCTAssertEqual(BluetoothDevice.describe([.read, .notify]), "read,notify")
        XCTAssertEqual(BluetoothDevice.describe([.write]), "write")
        XCTAssertEqual(BluetoothDevice.describe([]), "none")
    }
}

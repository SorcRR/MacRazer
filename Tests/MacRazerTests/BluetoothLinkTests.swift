// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
import CoreBluetooth
@testable import MacRazer

/// Which link MacRazer talks to the mouse over when more than one is present, and when it
/// lets go of one. Both rules came from hardware: a dongle left plugged in while the mouse
/// is on Bluetooth enumerates fine but times out forever.
final class BluetoothLinkTests: XCTestCase {
    func testCableBeatsBluetooth() {
        XCTAssertFalse(MouseController.prefersBluetooth(over: .wired, bluetoothControllable: true),
                       "a cable carries everything Bluetooth does and more")
    }

    func testBluetoothBeatsAnIdleDongle() {
        XCTAssertTrue(MouseController.prefersBluetooth(over: .wirelessDongle, bluetoothControllable: true))
    }

    func testUSBKeptWithoutAControllableBluetoothMouse() {
        XCTAssertFalse(MouseController.prefersBluetooth(over: .wirelessDongle, bluetoothControllable: false))
        XCTAssertFalse(MouseController.prefersBluetooth(over: nil, bluetoothControllable: true),
                       "an unknown USB model may be a cable; keep it")
    }

    func testTheDeviceTestKnowsWhenTheAppWouldPickBluetooth() {
        // The test can't use Bluetooth, so it stops before opening it, on exactly the cases
        // `openTransport` would pick it.
        func bt(_ present: Bool, _ connection: RazerConnection?, _ controllable: Bool) -> Bool {
            MouseController.wouldOpenBluetooth(usbPresent: present, usbConnection: connection,
                                               bluetoothControllable: controllable)
        }
        XCTAssertTrue(bt(false, nil, true), "nothing on USB")
        XCTAssertTrue(bt(true, .wirelessDongle, true), "an idle dongle")
        XCTAssertFalse(bt(true, .wired, true), "a cable")
        XCTAssertFalse(bt(true, nil, true), "an unknown USB model")
        XCTAssertFalse(bt(false, nil, false), "a Bluetooth mouse the app can't control is never opened")
    }

    func testTimeoutKeepsTheHandleOnlyWhenNothingBetterExists() {
        // The existing rule: a known serial keeps the handle through a timeout.
        XCTAssertTrue(MouseController.keepsHandleOnTimeout(serialKnown: true, onDongle: true,
                                                            bluetoothControllable: { false }))
        // Without letting go, the app would never move from a silent dongle to Bluetooth.
        XCTAssertFalse(MouseController.keepsHandleOnTimeout(serialKnown: true, onDongle: true,
                                                             bluetoothControllable: { true }))
        XCTAssertTrue(MouseController.keepsHandleOnTimeout(serialKnown: true, onDongle: false,
                                                            bluetoothControllable: { true }),
                      "a Bluetooth or cable handle keeps the old behaviour")
        XCTAssertFalse(MouseController.keepsHandleOnTimeout(serialKnown: false, onDongle: false,
                                                             bluetoothControllable: { false }))
    }

    func testBluetoothLookupSkippedWhenNotOnADongle() {
        var asked = false
        _ = MouseController.keepsHandleOnTimeout(serialKnown: true, onDongle: false,
                                                 bluetoothControllable: { asked = true; return true })
        XCTAssertFalse(asked, "the IOHID enumeration only runs when it can change the answer")
    }

    // MARK: Recognising the mouse on Bluetooth

    func testControllableNeedsTheExactBluetoothIDs() {
        XCTAssertEqual(HIDDevice.classifyBluetoothMouse(vendorID: 0x068E, productID: 0x00DC, name: "Cobra HS"),
                       HIDDevice.BluetoothMouse(name: "Cobra HS", controllablePID: 0x00DC))
        // Same name, unknown id: recognised for the hint, never driven.
        XCTAssertEqual(HIDDevice.classifyBluetoothMouse(vendorID: 0x068E, productID: 0x0001, name: "Cobra HS"),
                       HIDDevice.BluetoothMouse(name: "Cobra HS", controllablePID: nil))
    }

    func testOtherMiceAreIgnored() {
        XCTAssertNil(HIDDevice.classifyBluetoothMouse(vendorID: 0x004C, productID: 0x0269, name: "Magic Mouse"))
        XCTAssertNil(HIDDevice.classifyBluetoothMouse(vendorID: nil, productID: nil, name: "MX Master 3"))
    }

    func testNoticeState() {
        let supported = HIDDevice.BluetoothMouse(name: "Cobra HS", controllablePID: 0x00DC)
        let unsupported = HIDDevice.BluetoothMouse(name: "Viper V2", controllablePID: nil)
        XCTAssertEqual(BluetoothMouseStatus(supported, authorization: .allowedAlways), .connecting(name: "Cobra HS"))
        XCTAssertEqual(BluetoothMouseStatus(supported, authorization: .denied), .accessDenied(name: "Cobra HS"))
        XCTAssertEqual(BluetoothMouseStatus(unsupported, authorization: .denied), .needsModeSwitch(name: "Viper V2"),
                       "Bluetooth access can't help a model with no Bluetooth control")
    }
}

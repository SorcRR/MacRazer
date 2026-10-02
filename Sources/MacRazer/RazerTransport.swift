// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Common command surface for the existing USB protocol and the model-scoped BLE adapter.
/// The transport remains explicit so Bluetooth is never reported as USB or a dongle.
protocol RazerControlTransport: AnyObject {
    var productID: Int { get }
    var productName: String { get }
    var locationID: Int { get }
    var isBluetooth: Bool { get }
    func sendWithRetry(_ report: RazerReport) throws -> RazerReport
    func close()
}

extension HIDDevice: RazerControlTransport {
    var isBluetooth: Bool { false }
    func sendWithRetry(_ report: RazerReport) throws -> RazerReport {
        try sendWithRetry(report, attempts: 3)
    }
}

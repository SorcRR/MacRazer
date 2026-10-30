// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// What `MouseController` needs from a connected mouse, whichever link it is on: the USB
/// HID feature report (cable or 2.4 GHz dongle) or Razer's Bluetooth LE service.
/// Both speak `RazerReport`, so every command builder and parser is shared.
protocol RazerTransport: AnyObject {
    var productID: Int { get }
    var productName: String { get }
    /// Identifies the physical port for the serial cache. 0 on Bluetooth, where the
    /// product id alone tells a reconnect apart from a different mouse.
    var locationID: Int { get }
    var isBluetooth: Bool { get }
    func sendWithRetry(_ report: RazerReport) throws -> RazerReport
    func close()
}

extension HIDDevice: RazerTransport {
    var isBluetooth: Bool { false }
    func sendWithRetry(_ report: RazerReport) throws -> RazerReport {
        try sendWithRetry(report, attempts: HIDDevice.defaultAttempts)
    }
}

/// The retry ladder both transports share, so a policy change can't drift between them.
/// Falls through to the last error.
enum RazerRetry {
    static func run<T>(attempts: Int, _ body: () throws -> T) throws -> T {
        var lastError: Error = HIDDevice.HIDError.timeout
        for attempt in 0..<attempts {
            do {
                return try body()
            } catch HIDDevice.HIDError.notSupported {
                // Deterministic per model/command — retrying can't change the answer, and
                // the backoffs would just delay every poll on models lacking the feature.
                throw HIDDevice.HIDError.notSupported
            } catch HIDDevice.HIDError.notFound {
                // The device is gone (a Bluetooth link dropped); only a reopen can help.
                throw HIDDevice.HIDError.notFound
            } catch {
                lastError = error
                // No backoff after the final attempt: it would only delay reporting the
                // failure (offline detection, queued user writes on the serial queue).
                if attempt < attempts - 1 {
                    usleep(useconds_t(50_000 * (attempt + 1))) // 50ms, 100ms...
                }
            }
        }
        throw lastError
    }
}

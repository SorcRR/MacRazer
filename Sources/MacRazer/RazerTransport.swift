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

/// The mouse's button function table (`OnboardButtons`), over either link.
protocol ButtonFunctionTable {
    func readButtonBlock(_ id: UInt8) throws -> [UInt8]
    /// Writes one entry and reads it back; throws when the mouse doesn't hold it afterwards.
    func writeButtonBlock(_ id: UInt8, block: [UInt8]) throws
    /// One entry of the HyperShift layer; nil when nothing was ever written there, so the
    /// standard layer's function applies.
    func readShiftedBlock(_ id: UInt8) throws -> [UInt8]?
    /// Writes one HyperShift-layer entry and reads it back; throws when the mouse doesn't
    /// hold it afterwards.
    func writeShiftedBlock(_ id: UInt8, block: [UInt8]) throws
}

extension HIDDevice: ButtonFunctionTable {
    func readButtonBlock(_ id: UInt8) throws -> [UInt8] {
        guard let block = RazerCommands.parseButtonFunction(try sendWithRetry(RazerCommands.getButtonFunction(id)), id: id)
        else { throw HIDError.badResponse }
        return block
    }

    func writeButtonBlock(_ id: UInt8, block: [UInt8]) throws {
        _ = try sendWithRetry(RazerCommands.setButtonFunction(id, block: block))
        guard try readButtonBlock(id) == block else { throw HIDError.badResponse }
    }

    func readShiftedBlock(_ id: UInt8) throws -> [UInt8]? {
        let resp = try sendWithRetry(RazerCommands.getButtonFunction(id, layer: 0x01))
        switch RazerCommands.parseShiftedButtonFunction(resp, id: id) {
        case .set(let block): return block
        case .unset: return nil
        case nil: throw HIDError.badResponse
        }
    }

    func writeShiftedBlock(_ id: UInt8, block: [UInt8]) throws {
        _ = try sendWithRetry(RazerCommands.setButtonFunction(id, block: block, layer: 0x01))
        guard try readShiftedBlock(id) == block else { throw HIDError.badResponse }
    }
}

extension BluetoothDevice: ButtonFunctionTable {
    func readButtonBlock(_ id: UInt8) throws -> [UInt8] { try readButtonFunction(id).current }
    func writeButtonBlock(_ id: UInt8, block: [UInt8]) throws { try setButtonFunction(id, block: block) }
    func readShiftedBlock(_ id: UInt8) throws -> [UInt8]? { try readShiftedButtonFunction(id) }
    func writeShiftedBlock(_ id: UInt8, block: [UInt8]) throws { try setShiftedButtonFunction(id, block: block) }
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

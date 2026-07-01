// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import IOKit
import IOKit.hid

/// Thin wrapper over IOKit's HID Manager for talking to the Razer dongle.
///
/// We send a `razer_report` as a HID *feature* report and read the response back as a
/// feature report — mirroring how OpenRazer issues USB control transfers and how
/// 1kc/razer-macos issues feature reports from macOS userspace. No kernel extension needed.
///
/// Report ID: OpenRazer control messages use report id 0x00. We pass reportID 0 to
/// IOHIDDeviceGetReport/SetReport and send the raw 90-byte buffer. If the device NAKs,
/// the next thing to try is prefixing a report-id byte — verify against razer-macos.
final class HIDDevice {

    enum HIDError: Error, CustomStringConvertible {
        case notFound
        case openFailed(IOReturn)
        case setReportFailed(IOReturn)
        case getReportFailed(IOReturn)
        case badResponse
        case timeout

        var description: String {
            func hex(_ r: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: r)) }
            switch self {
            case .notFound: return "Razer Cobra HyperSpeed not found on USB (is the 2.4GHz dongle plugged in?)"
            case .openFailed(let r): return "IOHIDDeviceOpen failed: \(hex(r))"
            case .setReportFailed(let r): return "SetReport failed: \(hex(r))"
            case .getReportFailed(let r): return "GetReport failed: \(hex(r))"
            case .badResponse: return "Malformed response report"
            case .timeout: return "Device command timed out (known-finicky over the wireless dongle)"
            }
        }
    }

    /// Whether an error string from a failed open/read means the macOS Input Monitoring
    /// permission is missing. `HIDError` renders IOReturn codes as hex only, so match
    /// kIOReturnNotPermitted's hex form — a "NotPermitted" substring never appears.
    static func errorLooksPermissionDenied(_ text: String) -> Bool {
        text.contains("0xe00002e2") // kIOReturnNotPermitted
    }

    private let device: IOHIDDevice
    let productID: Int
    let productName: String

    private init(device: IOHIDDevice) {
        self.device = device
        self.productID = HIDDevice.intProp(device, kIOHIDProductIDKey) ?? 0
        // The device's own USB product string — works for any Razer mouse without a registry.
        let raw = HIDDevice.strProp(device, kIOHIDProductKey)?.trimmingCharacters(in: .whitespaces)
        self.productName = (raw?.isEmpty == false ? raw! : RazerDevices.info(pid: HIDDevice.intProp(device, kIOHIDProductIDKey) ?? 0)?.name) ?? "Razer Mouse"
    }

    private static func intProp(_ dev: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(dev, key as CFString) as? Int
    }
    private static func strProp(_ dev: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(dev, key as CFString) as? String
    }

    /// Enumerate every HID interface the matching device(s) expose. Do NOT open the
    /// manager — that grabs all interfaces (incl. the keyboard/mouse ones, which need
    /// Input Monitoring) and is what produced kIOReturnNotOpen. We only need the device
    /// list; opening happens per-device.
    /// All HID interfaces for the vendor (any product). We pick the right one by control score.
    static func matchingDevices(vendorId: Int) -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey as String: vendorId] as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return Array(set)
    }

    /// Razer mouse model keywords — used to recognise a Bluetooth-connected Razer mouse, which
    /// reports a generic (non-Razer) vendor id and a shortened product name (e.g. "Cobra HS").
    private static let razerMouseKeywords = [
        "razer", "cobra", "basilisk", "deathadder", "naga", "viper", "mamba",
        "lancehead", "orochi", "atheris", "hyperspeed",
    ]

    /// If a Razer mouse is currently connected over **Bluetooth**, returns its product name.
    /// Razer's control protocol (battery/DPI/lighting) is only exposed over USB — the 2.4GHz
    /// dongle or a wired cable — so a Bluetooth connection enumerates as a plain HID mouse with
    /// a non-Razer vendor id and no control interface. We detect it by transport + model name
    /// so the UI can explain why control is unavailable and prompt switching to 2.4GHz / USB-C.
    static func bluetoothRazerMouseName() -> String? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Generic Desktop (0x01) / Mouse (0x02), any vendor — the BLE mouse isn't VID 0x1532.
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey as String: 0x01,
            kIOHIDDeviceUsageKey as String: 0x02,
        ] as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        for dev in set {
            let transport = strProp(dev, kIOHIDTransportKey) ?? ""
            guard transport.localizedCaseInsensitiveContains("Bluetooth"),
                  let name = strProp(dev, kIOHIDProductKey) else { continue }
            let lower = name.lowercased()
            if razerMouseKeywords.contains(where: { lower.contains($0) }) { return name }
        }
        return nil
    }

    /// One-line description of an interface, for the `info` diagnostic.
    static func describe(_ dev: IOHIDDevice) -> String {
        let pid = intProp(dev, kIOHIDProductIDKey) ?? 0
        let up = intProp(dev, kIOHIDPrimaryUsagePageKey) ?? 0
        let usage = intProp(dev, kIOHIDPrimaryUsageKey) ?? 0
        let maxFeat = intProp(dev, kIOHIDMaxFeatureReportSizeKey) ?? 0
        let maxIn = intProp(dev, kIOHIDMaxInputReportSizeKey) ?? 0
        let loc = intProp(dev, kIOHIDLocationIDKey) ?? 0
        let transport = strProp(dev, kIOHIDTransportKey) ?? "?"
        return String(
            format: "pid=0x%04x usagePage=0x%02x usage=0x%02x maxFeature=%d maxInput=%d transport=%@ loc=0x%x",
            pid, up, usage, maxFeat, maxIn, transport, loc
        )
    }

    /// Find and open the *control* interface: the one that can carry our 90-byte feature
    /// report. We prefer (a) a vendor-defined usage page (>= 0xFF00), then (b) the largest
    /// MaxFeatureReportSize. The keyboard/mouse interfaces report tiny/zero feature sizes.
    static func open(vendorId: Int) throws -> HIDDevice {
        let devices = matchingDevices(vendorId: vendorId)
        guard !devices.isEmpty else { throw HIDError.notFound }

        // Only consider interfaces that can carry the 90-byte Razer control report.
        let candidates = devices.filter { (intProp($0, kIOHIDMaxFeatureReportSizeKey) ?? 0) >= 90 }
        guard let chosen = candidates.max(by: { controlScore($0) < controlScore($1) }) else {
            throw HIDError.notFound
        }

        print("  → control interface: \(describe(chosen))")
        let openResult = IOHIDDeviceOpen(chosen, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { throw HIDError.openFailed(openResult) }
        return HIDDevice(device: chosen)
    }

    /// Higher score = more likely to be the mouse's Razer control interface.
    private static func controlScore(_ dev: IOHIDDevice) -> Int {
        let up = intProp(dev, kIOHIDPrimaryUsagePageKey) ?? 0
        let usage = intProp(dev, kIOHIDPrimaryUsageKey) ?? 0
        let maxFeat = intProp(dev, kIOHIDMaxFeatureReportSizeKey) ?? 0
        var score = maxFeat                 // prefer interfaces that carry big feature reports
        if up >= 0xFF00 { score += 1000 }   // vendor-defined usage page (some models)
        if up == 0x01 && usage == 0x02 { score += 500 } // prefer the Mouse interface over a keyboard
        return score
    }

    /// Wait between SetReport and GetReport, in microseconds. Cobra Pro / HyperSpeed route
    /// through `RAZER_NEW_MOUSE_RECEIVER_WAIT_US` = 31000µs in OpenRazer. Too short a wait
    /// returns status 0x01 (BUSY) with empty arguments.
    static let receiverWaitUs: useconds_t = 31_000

    /// Send a report and read the response. Razer's request/response pattern: SetReport the
    /// request, sleep the receiver wait, then GetReport. If the device replies BUSY (0x01),
    /// it hasn't finished yet — wait and re-read a few times before giving up.
    func send(_ report: RazerReport) throws -> RazerReport {
        let out = report.serialized()
        let setResult = out.withUnsafeBufferPointer { ptr in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, ptr.baseAddress!, ptr.count)
        }
        guard setResult == kIOReturnSuccess else { throw HIDError.setReportFailed(setResult) }

        usleep(HIDDevice.receiverWaitUs)

        // Re-read while the device reports BUSY.
        for busyAttempt in 0..<5 {
            var inBuf = [UInt8](repeating: 0, count: RazerReport.wireSize)
            var inLen = inBuf.count
            let getResult = inBuf.withUnsafeMutableBufferPointer { ptr in
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, ptr.baseAddress!, &inLen)
            }
            guard getResult == kIOReturnSuccess else { throw HIDError.getReportFailed(getResult) }
            guard let parsed = RazerReport.parse(inBuf) else { throw HIDError.badResponse }

            switch parsed.status {
            case RazerStatus.busy.rawValue:
                usleep(HIDDevice.receiverWaitUs * useconds_t(busyAttempt + 1))
                continue
            case RazerStatus.timeout.rawValue:
                throw HIDError.timeout
            default:
                return parsed // 0x02 successful (and anything else the caller can inspect)
            }
        }
        throw HIDError.timeout
    }

    /// Send with retry + linear backoff — the wireless dongle is documented as finicky and
    /// battery reads in particular time out intermittently. Falls through to the last error.
    func sendWithRetry(_ report: RazerReport, attempts: Int = 3) throws -> RazerReport {
        var lastError: Error = HIDError.timeout
        for attempt in 0..<attempts {
            do {
                return try send(report)
            } catch {
                lastError = error
                usleep(useconds_t(50_000 * (attempt + 1))) // 50ms, 100ms, 150ms...
            }
        }
        throw lastError
    }

    func close() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

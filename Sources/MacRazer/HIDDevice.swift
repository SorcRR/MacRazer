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
        case commandFailed
        case notSupported

        var description: String {
            func hex(_ r: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: r)) }
            switch self {
            case .notFound: return "No Razer mouse found on USB (is the cable or 2.4GHz dongle plugged in?)"
            case .openFailed(let r): return "IOHIDDeviceOpen failed: \(hex(r))"
            case .setReportFailed(let r): return "SetReport failed: \(hex(r))"
            case .getReportFailed(let r): return "GetReport failed: \(hex(r))"
            case .badResponse: return "Malformed or mismatched response report"
            case .timeout: return "Device command timed out (known-finicky over the wireless dongle)"
            case .commandFailed: return "Device reported the command failed (status 0x03)"
            case .notSupported: return "Device reports the command as not supported (status 0x05)"
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
    /// Where the device sits on the USB bus. Stable for as long as it stays plugged in.
    let locationID: Int

    private init(device: IOHIDDevice) {
        self.device = device
        self.productID = HIDDevice.intProp(device, kIOHIDProductIDKey) ?? 0
        self.locationID = HIDDevice.intProp(device, kIOHIDLocationIDKey) ?? 0
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

    /// Every HID interface matching `criteria` (an IOHID matching dictionary). The one place
    /// that builds a manager and enumerates, so a fix to the pattern lands once.
    static func devices(matching criteria: [String: Any]) -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, criteria as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return Array(set)
    }

    /// Enumerate every HID interface the matching device(s) expose. Do NOT open the
    /// manager — that grabs all interfaces (incl. the keyboard/mouse ones, which need
    /// Input Monitoring) and is what produced kIOReturnNotOpen. We only need the device
    /// list; opening happens per-device.
    /// All HID interfaces for the vendor (any product). We pick the right one by control score.
    static func matchingDevices(vendorId: Int) -> [IOHIDDevice] {
        devices(matching: [kIOHIDVendorIDKey as String: vendorId])
    }

    /// Razer mouse model keywords — used to recognise a Bluetooth-connected Razer mouse, which
    /// reports a generic (non-Razer) vendor id and a shortened product name (e.g. "Cobra HS").
    private static let razerMouseKeywords = [
        "razer", "cobra", "basilisk", "deathadder", "naga", "viper", "mamba",
        "lancehead", "orochi", "atheris", "hyperspeed",
    ]

    /// A Razer mouse macOS has connected over Bluetooth.
    struct BluetoothMouse: Equatable {
        let name: String
        /// Set when the registry can control this model over Bluetooth
        /// (`RazerDevices.bluetoothPIDs`), through Razer's GATT service (`BluetoothDevice`).
        let controllablePID: Int?
    }

    /// The Razer mouse connected over **Bluetooth**, if any, preferring one MacRazer can
    /// control. Over Bluetooth the mouse enumerates as a plain HID mouse with no control
    /// interface, so this is plain IOHID enumeration: nothing is opened, no permission is
    /// needed, and CoreBluetooth (with its permission prompt) stays away from everyone who
    /// has no such mouse. Models without Bluetooth control are recognised by name so the UI
    /// can explain why and prompt switching to 2.4GHz / USB-C.
    static func bluetoothRazerMouse() -> BluetoothMouse? {
        // Generic Desktop (0x01) / Mouse (0x02), any vendor — the BLE mouse isn't VID 0x1532.
        let found = devices(matching: [
            kIOHIDDeviceUsagePageKey as String: 0x01,
            kIOHIDDeviceUsageKey as String: 0x02,
        ]).compactMap { dev -> BluetoothMouse? in
            guard (strProp(dev, kIOHIDTransportKey) ?? "").localizedCaseInsensitiveContains("Bluetooth"),
                  let name = strProp(dev, kIOHIDProductKey) else { return nil }
            return classifyBluetoothMouse(vendorID: intProp(dev, kIOHIDVendorIDKey),
                                          productID: intProp(dev, kIOHIDProductIDKey), name: name)
        }
        return found.first { $0.controllablePID != nil } ?? found.first
    }

    /// Whether a Bluetooth HID mouse is a Razer one, and one we can control. Control needs
    /// the exact Bluetooth vendor and product id (a name match could be another model on the
    /// same service); recognising it for the hint only needs the name.
    static func classifyBluetoothMouse(vendorID: Int?, productID: Int?, name: String) -> BluetoothMouse? {
        if vendorID == BLEProtocol.vendorId, let pid = productID, RazerDevices.bluetoothPIDs.contains(pid) {
            return BluetoothMouse(name: name, controllablePID: pid)
        }
        let lower = name.lowercased()
        guard razerMouseKeywords.contains(where: { lower.contains($0) }) else { return nil }
        return BluetoothMouse(name: name, controllablePID: nil)
    }

    /// Every HID interface the vendor's devices expose, in a stable order, and which one
    /// `open(vendorId:)` would pick for control. For the device test's report; the order is
    /// sorted because macOS returns the set in no particular order.
    static func interfaceSummaries(vendorId: Int) -> (interfaces: [DeviceProbe.Interface], control: Int?) {
        let devices = matchingDevices(vendorId: vendorId)
        let summaries = devices.map { dev in
            DeviceProbe.Interface(
                productID: intProp(dev, kIOHIDProductIDKey) ?? 0,
                product: strProp(dev, kIOHIDProductKey) ?? "",
                usagePage: intProp(dev, kIOHIDPrimaryUsagePageKey) ?? 0,
                usage: intProp(dev, kIOHIDPrimaryUsageKey) ?? 0,
                maxFeatureReportSize: intProp(dev, kIOHIDMaxFeatureReportSizeKey) ?? 0,
                maxInputReportSize: intProp(dev, kIOHIDMaxInputReportSizeKey) ?? 0,
                transport: strProp(dev, kIOHIDTransportKey) ?? "")
        }
        // The same choice `controlInterface(vendorId:)` makes, so the report names the one opened.
        let chosen = HIDDeviceSelection.controlInterfaceIndex(interfaces: interfaceInfos(devices)).map { summaries[$0] }
        let sorted = summaries.sorted {
            ($0.productID, $0.usagePage, $0.usage, $0.maxFeatureReportSize, $0.maxInputReportSize)
                < ($1.productID, $1.usagePage, $1.usage, $1.maxFeatureReportSize, $1.maxInputReportSize)
        }
        return (sorted, chosen.flatMap { sorted.firstIndex(of: $0) })
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

    /// Find and open the control interface. Which physical device (and which of its
    /// interfaces) wins is decided by `HIDDeviceSelection` — matching is vendor-wide, so
    /// with a Razer keyboard or second mouse attached, the mouse must be picked by rank
    /// (registry-known PID → mouse-usage device → score), not by raw interface score.
    static func open(vendorId: Int) throws -> HIDDevice {
        try open(controlInterface(vendorId: vendorId))
    }

    /// The control interface `open(vendorId:)` would pick, without opening it — so a caller
    /// can look at its product id first (see `MouseController.openTransport`).
    static func controlInterface(vendorId: Int) throws -> IOHIDDevice {
        let devices = matchingDevices(vendorId: vendorId)
        guard !devices.isEmpty else { throw HIDError.notFound }

        guard let idx = HIDDeviceSelection.controlInterfaceIndex(interfaces: interfaceInfos(devices)) else {
            throw HIDError.notFound
        }
        return devices[idx]
    }

    /// What `HIDDeviceSelection` ranks each interface by.
    private static func interfaceInfos(_ devices: [IOHIDDevice]) -> [HIDInterfaceInfo] {
        devices.map { dev in
            HIDInterfaceInfo(pid: intProp(dev, kIOHIDProductIDKey) ?? 0,
                             locationID: intProp(dev, kIOHIDLocationIDKey) ?? 0,
                             usagePage: intProp(dev, kIOHIDPrimaryUsagePageKey) ?? 0,
                             usage: intProp(dev, kIOHIDPrimaryUsageKey) ?? 0,
                             maxFeatureReportSize: intProp(dev, kIOHIDMaxFeatureReportSizeKey) ?? 0)
        }
    }

    static func productID(of dev: IOHIDDevice) -> Int { intProp(dev, kIOHIDProductIDKey) ?? 0 }

    static func open(_ chosen: IOHIDDevice) throws -> HIDDevice {
        // stderr, not stdout: this fires on every (re)open inside the GUI app too, and the
        // CLI's actual output goes to stdout.
        FileHandle.standardError.write(Data("[MacRazer] control interface: \(describe(chosen))\n".utf8))
        let openResult = IOHIDDeviceOpen(chosen, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { throw HIDError.openFailed(openResult) }
        return HIDDevice(device: chosen)
    }

    /// Wait between SetReport and GetReport, in microseconds. Cobra Pro / HyperSpeed route
    /// through `RAZER_NEW_MOUSE_RECEIVER_WAIT_US` = 31000µs in OpenRazer. Too short a wait
    /// returns status 0x01 (BUSY) with empty arguments.
    static let receiverWaitUs: useconds_t = 31_000

    /// Send a report and read the response. Razer's request/response pattern: SetReport the
    /// request, sleep the receiver wait, then GetReport. If the device replies BUSY (0x01),
    /// it hasn't finished yet — wait and re-read a few times before giving up.
    func send(_ report: RazerReport) throws -> RazerReport {
        try send(report, transactionId: nil)
    }

    /// `transactionId` overrides the registry's for this one command. Only the device test
    /// passes one, to find which id an unknown model answers to; everything else passes nil.
    func send(_ report: RazerReport, transactionId: UInt8?) throws -> RazerReport {
        var report = report
        // Per-model (and per-command-class) transaction id from the registry, stamped at
        // the single point every command passes through — the builders in `RazerCommands`
        // stay model-agnostic.
        report.transactionId = transactionId ?? RazerDevices.transactionId(
            pid: productID, commandClass: report.commandClass, commandId: report.commandId)
        let out = report.serialized()
        let setResult = out.withUnsafeBufferPointer { ptr in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, ptr.baseAddress!, ptr.count)
        }
        guard setResult == kIOReturnSuccess else { throw HIDError.setReportFailed(setResult) }

        usleep(HIDDevice.receiverWaitUs)

        // Re-read while the device reports BUSY, hands back a short/stale/mismatched
        // report, or hasn't written a response yet.
        var lastProblem = HIDError.timeout
        for busyAttempt in 0..<5 {
            var inBuf = [UInt8](repeating: 0, count: RazerReport.wireSize)
            var inLen = inBuf.count
            let getResult = inBuf.withUnsafeMutableBufferPointer { ptr in
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, ptr.baseAddress!, &inLen)
            }
            guard getResult == kIOReturnSuccess else { throw HIDError.getReportFailed(getResult) }
            // A short transfer leaves the pre-zeroed buffer parsing as an all-zeros
            // "success" with zero arguments — not-ready, not data. Re-read.
            guard inLen == RazerReport.wireSize, let parsed = RazerReport.parse(inBuf) else {
                lastProblem = .badResponse
                if busyAttempt < 4 { usleep(HIDDevice.receiverWaitUs * useconds_t(busyAttempt + 1)) }
                continue
            }
            // A response that doesn't echo the request's command bytes is stale — the
            // previous command's reply still sitting in the buffer, or a zeroed
            // placeholder. Consuming it would publish another command's arguments as this
            // one's data (OpenRazer rejects these the same way). Re-read.
            guard parsed.commandClass == report.commandClass, parsed.commandId == report.commandId else {
                lastProblem = .badResponse
                if busyAttempt < 4 { usleep(HIDDevice.receiverWaitUs * useconds_t(busyAttempt + 1)) }
                continue
            }

            switch parsed.status {
            case RazerStatus.busy.rawValue:
                // Verified on the HyperSpeed: BUSY here means "response not ready yet" and
                // a re-read returns the real reply. (OpenRazer notes some commands on other
                // models reply BUSY yet succeed; such a model would mis-report writes here.)
                lastProblem = .timeout
                if busyAttempt < 4 { usleep(HIDDevice.receiverWaitUs * useconds_t(busyAttempt + 1)) }
                continue
            case RazerStatus.timeout.rawValue:
                throw HIDError.timeout
            case RazerStatus.failure.rawValue:
                // Parsing a failure reply's arguments as real data is how a garbage
                // brightness/DPI ends up in the UI (or persisted into a profile).
                throw HIDError.commandFailed
            case RazerStatus.notSupported.rawValue:
                throw HIDError.notSupported
            default:
                return parsed // 0x02 successful (unknown statuses pass through, like OpenRazer)
            }
        }
        throw lastProblem
    }

    /// How many tries everyday traffic gets. `DeviceProbe` uses the same number, so a probe
    /// that passes says the app's own reads and writes will too.
    static let defaultAttempts = 3

    /// Send with retry + linear backoff — the wireless dongle is documented as finicky and
    /// battery reads in particular time out intermittently. See `RazerRetry`.
    func sendWithRetry(_ report: RazerReport, attempts: Int = HIDDevice.defaultAttempts) throws -> RazerReport {
        try sendWithRetry(report, attempts: attempts, transactionId: nil)
    }

    /// As above, with the transaction id override `send(_:transactionId:)` describes.
    func sendWithRetry(_ report: RazerReport, attempts: Int, transactionId: UInt8?) throws -> RazerReport {
        try RazerRetry.run(attempts: attempts) { try send(report, transactionId: transactionId) }
    }

    func close() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// A diagnostic trace of gesture holds and of what the mouse reports, off unless asked for.
/// Lines go to `~/Library/Logs/MacRazer/gesture.log`. It exists because nothing outside the
/// app can watch what its event tap receives: another process needs its own Input Monitoring
/// grant to see the same events.
///
/// One defaults key, read once at launch, so relaunch after changing it.
///
///     defaults write com.macrazer.menubar gestureDebugLog -bool true
///
/// turns the trace on. It records button and F20 timing and pointer deltas from the event tap;
/// the mouse's own HID input reports other than pointer movement (`GestureDebugHIDWatch`,
/// lines `HIDREPORT id=<n> len=<n> <hex>`); every characteristic of Razer's Bluetooth service
/// (`GATT <uuid> properties=...`) and every value the mouse sends there that isn't part of a
/// reply the app is waiting for (`BLE unsolicited <uuid>: <hex>`); and once per Bluetooth
/// connection, after the reads the connection starts with, a fixed list of vendor reads
/// (`BLEProtocol.traceProbeKeys`, lines `BLEREAD <key> -> <status, header, payload>`). The
/// trace itself only reads: it changes nothing on the mouse. It never records what is typed:
/// keyboards aren't watched, and the mouse's own keyboard report is logged only when the keys
/// in it are F13 to F20 (`GestureDebugReportFilter`).
///
/// It also records what MacRazer itself does with the DPI button on a mouse that reports it as
/// private keys (`RazerDevices.dpiButtonPrivateKeys`): each read and write of the device mode
/// and why (`DEVMODE` lines, from `MouseController` and `BluetoothDevice`), the private keys as
/// they go down and up (`PRIVKEY` lines, `DpiPrivateKeyWatcher`), and the stages a short press
/// steps to (`DPI cycle`).
///
/// To turn it off:
///
///     defaults delete com.macrazer.menubar gestureDebugLog
///
/// then relaunch.
enum GestureDebugLog {
    static let defaultsKey = "gestureDebugLog"

    /// Read once: the tap's hot path must not ask UserDefaults per event.
    static let enabled = UserDefaults.standard.bool(forKey: defaultsKey)

    private static let start = Date()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacRazer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("gesture.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    /// Any thread: the tap on the main thread, Bluetooth on its own queue, the probes on the
    /// device queue. The message is an autoclosure so a disabled log costs one boolean test.
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        lock.lock()
        defer { lock.unlock() }
        let line = String(format: "%9.3f %@\n", Date().timeIntervalSince(start), text)
        handle?.write(Data(line.utf8))
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// A trace reply as `BLEREAD` and `DEVMODE` lines show it: the status, any earlier status a
    /// later header for the same request replaced, the declared length (and how many bytes came
    /// when that differs), the header frame, then every payload byte.
    static func describe(_ reply: BLEProtocol.TraceAssembler, timedOut: Bool) -> String {
        guard let header = reply.header, let status = reply.status else {
            return timedOut ? "timeout, no reply" : "no reply"
        }
        var text = timedOut ? "timeout " : ""
        text += String(format: "status=%02x", status)
        if !reply.replacedStatuses.isEmpty { text += " (after \(hex(reply.replacedStatuses)))" }
        text += " len=\(reply.declaredLength)"
        if reply.payload.count != reply.declaredLength { text += " got=\(reply.payload.count)" }
        text += " hdr=\(hex(header))"
        if !reply.payload.isEmpty { text += ": \(hex(reply.payload))" }
        return text
    }
}

import IOKit.hid

/// What the trace may log of one HID input report from a watched mouse. Pure, so the rule that
/// nothing typed is recorded is tested.
enum GestureDebugReportFilter {
    /// Pointer movement, at the polling rate, never logged: report 1 on the Cobra HyperSpeed
    /// over Bluetooth, and 0, a device without report ids, whose one report is the pointer.
    static let pointerReportIDs: Set<Int> = [0, 1]
    /// The mouse's keyboard collection on the Cobra HyperSpeed over Bluetooth: what a button
    /// bound to a key types.
    static let keyboardReportIDs: Set<Int> = [6]
    /// F13 to F20, what a remapped mouse button types (F20 is the DPI button's bridge).
    static let loggableKeys: ClosedRange<UInt8> = 0x68...0x6F

    /// The `HIDREPORT` line for a report, or nil for a pointer report. A keyboard report is
    /// logged only when every non-zero byte after its report id is F13 to F20, modifiers
    /// included, so a release (all zeros) is logged and anything else typed is not.
    static func line(reportID: Int, bytes: [UInt8], pointer: Set<Int> = pointerReportIDs,
                     keyboard: Set<Int> = keyboardReportIDs) -> String? {
        guard !pointer.contains(reportID) else { return nil }
        if keyboard.contains(reportID) {
            let keys = reportID != 0 && bytes.first == UInt8(truncatingIfNeeded: reportID) ? bytes.dropFirst() : bytes[...]
            guard keys.allSatisfy({ $0 == 0 || loggableKeys.contains($0) }) else {
                return "HIDREPORT id=\(reportID) (not recorded)"
            }
        }
        return "HIDREPORT id=\(reportID) len=\(bytes.count) \(GestureDebugLog.hex(bytes))"
    }

    /// Caps the reports of one id logged per second, so one that streams can't fill the disk.
    struct RateLimit {
        static let perSecond = 40
        private var windows: [Int: (second: Int, count: Int, dropped: Int)] = [:]

        /// Whether to log this report, and how many of its id went unlogged in the last second
        /// that had any, to say so once.
        mutating func admit(reportID: Int, at time: TimeInterval) -> (log: Bool, droppedBefore: Int) {
            let second = Int(time.rounded(.down))
            var window = windows[reportID] ?? (second: second, count: 0, dropped: 0)
            var droppedBefore = 0
            if window.second != second {
                droppedBefore = window.dropped
                window = (second: second, count: 0, dropped: 0)
            }
            window.count += 1
            let log = window.count <= Self.perSecond
            if !log { window.dropped += 1 }
            windows[reportID] = window
            return (log, droppedBefore)
        }
    }
}

/// With the trace on, also record what the mouse itself reports at the HID level, apart from
/// pointer movement: a button the firmware handles on its own (the Cobra's DPI button) may
/// still say something when it goes down, which only shows here. Whole input reports, not
/// element values: the Cobra over Bluetooth declares its reports 4 and 5 as arrays of Generic
/// Desktop usage 0x03, which a filter on usage pages can't tell from pointer movement.
///
/// Main thread only, like the run loop it schedules on.
enum GestureDebugHIDWatch {
    nonisolated(unsafe) private static var manager: IOHIDManager?
    nonisolated(unsafe) private static var watched: [Watched] = []

    /// One mouse interface being watched: the buffer its reports land in, sized from its
    /// largest input report and kept until the device goes away, and which of its report ids
    /// are pointer and keyboard ones, from its descriptor as well as the defaults.
    private final class Watched: @unchecked Sendable {
        let device: IOHIDDevice
        let name: String
        let buffer: UnsafeMutablePointer<UInt8>
        let size: Int
        let pointerIDs: Set<Int>
        let keyboardIDs: Set<Int>
        var rate = GestureDebugReportFilter.RateLimit()

        init(device: IOHIDDevice, name: String, size: Int, pointerIDs: Set<Int>, keyboardIDs: Set<Int>) {
            self.device = device
            self.name = name
            self.size = size
            self.pointerIDs = pointerIDs
            self.keyboardIDs = keyboardIDs
            buffer = .allocate(capacity: size)
        }

        deinit { buffer.deallocate() }

        func received(reportID: Int, bytes: [UInt8]) {
            guard let line = GestureDebugReportFilter.line(reportID: reportID, bytes: bytes,
                                                           pointer: pointerIDs, keyboard: keyboardIDs) else { return }
            let verdict = rate.admit(reportID: reportID, at: ProcessInfo.processInfo.systemUptime)
            if verdict.droppedBefore > 0 {
                GestureDebugLog.log("HIDREPORT id=\(reportID) \(verdict.droppedBefore) more not logged "
                                    + "(over \(GestureDebugReportFilter.RateLimit.perSecond) a second)")
            }
            if verdict.log { GestureDebugLog.log(line) }
        }
    }

    /// Whether a HID device is one the trace watches: a Razer mouse, never a keyboard. Over
    /// Bluetooth (vendor 0x068E), a mouse by its primary usage or by a product id MacRazer
    /// knows there. On a cable or dongle (0x1532), only an interface whose primary usage is the
    /// mouse, of a product the registry lists as a mouse, so no interface of a Razer keyboard.
    static func watches(vendorID: Int, productID: Int, primaryUsagePage: Int, primaryUsage: Int) -> Bool {
        let isMouse = primaryUsagePage == kHIDPage_GenericDesktop && primaryUsage == kHIDUsage_GD_Mouse
        let isKeyboard = primaryUsagePage == kHIDPage_KeyboardOrKeypad
            || (primaryUsagePage == kHIDPage_GenericDesktop
                && (primaryUsage == kHIDUsage_GD_Keyboard || primaryUsage == kHIDUsage_GD_Keypad))
        guard !isKeyboard else { return false }
        switch vendorID {
        case BLEProtocol.vendorId:
            return isMouse || RazerDevices.bluetoothPIDs.contains(productID)
        case Razer.vendorId:
            return isMouse && RazerDevices.info(pid: productID) != nil && RazerAccessories.info(pid: productID) == nil
        default:
            return false
        }
    }

    /// Main thread, once. Needs Input Monitoring, which the F20 bridge and the DPI button's
    /// private keys need anyway.
    static func startIfEnabled() {
        guard GestureDebugLog.enabled, manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let mouse = [kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop, kIOHIDPrimaryUsageKey: kHIDUsage_GD_Mouse]
        // Narrower than `watches`, so the manager opens as little as it can; `watches` decides.
        let matching: [[String: Int]] = [mouse.merging([kIOHIDVendorIDKey: BLEProtocol.vendorId]) { $1 }]
            + RazerDevices.bluetoothPIDs.sorted().map { [kIOHIDVendorIDKey: BLEProtocol.vendorId, kIOHIDProductIDKey: $0] }
            + [mouse.merging([kIOHIDVendorIDKey: Razer.vendorId]) { $1 }]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
            GestureDebugHIDWatch.matched(device)
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, device in
            GestureDebugHIDWatch.removed(device)
        }, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        GestureDebugLog.log("HID watch open result=\(HIDDevice.HIDError.hex(result))")
        self.manager = manager
    }

    private static func matched(_ device: IOHIDDevice) {
        func number(_ key: String) -> Int { IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? 0 }
        let vendor = number(kIOHIDVendorIDKey), product = number(kIOHIDProductIDKey)
        let page = number(kIOHIDPrimaryUsagePageKey), usage = number(kIOHIDPrimaryUsageKey)
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
        let name = String(format: "vendor=%04x product=%04x usage=%02x:%02x transport=", vendor, product, page, usage)
            + transport
        guard watches(vendorID: vendor, productID: product, primaryUsagePage: page, primaryUsage: usage) else {
            GestureDebugLog.log("HID watch skips \(name)")
            return
        }
        guard !watched.contains(where: { CFEqual($0.device, device) }) else { return }
        let size = number(kIOHIDMaxInputReportSizeKey)
        let open = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        let opened = "open=\(HIDDevice.HIDError.hex(open)) maxInputReport=\(size)"
        guard size > 0, open == kIOReturnSuccess else {
            GestureDebugLog.log("HID watch matched \(name) \(opened), not watching")
            return
        }
        let ids = reportIDs(of: device)
        let entry = Watched(device: device, name: name, size: size, pointerIDs: ids.pointer, keyboardIDs: ids.keyboard)
        IOHIDDeviceRegisterInputReportCallback(device, entry.buffer, size, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            Unmanaged<Watched>.fromOpaque(context).takeUnretainedValue()
                .received(reportID: Int(reportID), bytes: Array(UnsafeBufferPointer(start: report, count: max(0, length))))
        }, Unmanaged.passUnretained(entry).toOpaque())
        watched.append(entry)
        GestureDebugLog.log("HID watch matched \(name) \(opened) skipping ids \(ids.pointer.sorted()), "
                            + "F13-F20 only in ids \(ids.keyboard.sorted())")
    }

    private static func removed(_ device: IOHIDDevice) {
        guard let index = watched.firstIndex(where: { CFEqual($0.device, device) }) else { return }
        let entry = watched.remove(at: index)
        IOHIDDeviceRegisterInputReportCallback(device, entry.buffer, entry.size, nil, nil)
        GestureDebugLog.log("HID watch removed \(entry.name)")
        // The buffer goes on the next turn of the run loop, not inside IOKit's own call.
        DispatchQueue.main.async { withExtendedLifetime(entry) {} }
    }

    /// The report ids the descriptor puts pointer axes and keyboard keys in, on top of the
    /// filter's defaults.
    private static func reportIDs(of device: IOHIDDevice) -> (pointer: Set<Int>, keyboard: Set<Int>) {
        var pointer = GestureDebugReportFilter.pointerReportIDs
        var keyboard = GestureDebugReportFilter.keyboardReportIDs
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        for element in elements {
            let page = Int(IOHIDElementGetUsagePage(element)), usage = Int(IOHIDElementGetUsage(element))
            let id = Int(IOHIDElementGetReportID(element))
            if page == kHIDPage_KeyboardOrKeypad { keyboard.insert(id) }
            if page == kHIDPage_GenericDesktop, usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y { pointer.insert(id) }
        }
        return (pointer, keyboard)
    }
}

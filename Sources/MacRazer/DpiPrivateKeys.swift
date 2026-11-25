// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import IOKit
import IOKit.hid

/// The private keys a mouse's DPI button reports in driver mode (`RazerDevices.dpiButtonPrivateKeys`).
struct DpiButtonPrivateKeys: Equatable, Sendable {
    /// Reported when a short press is released, and held for about 55 ms.
    let short: UInt8
    /// Reported once the firmware recognises a long press, about a second after the button
    /// went down, and held until it comes up.
    let long: UInt8

    /// Synapse's "DPI cycle" and "AI launcher" keys, as the Cobra HyperSpeed reports them.
    static let cobraHyperSpeed = DpiButtonPrivateKeys(short: 0x52, long: 0xD2)
}

/// One change in the private keys held: `code` went down or came up.
struct PrivateKeyEvent: Equatable, Sendable {
    let code: UInt8
    let isDown: Bool
    /// The key "came up" only because the device that held it went away
    /// (`PrivateKeyTracker.sourceGone`), the mouse disconnecting most often: the button may
    /// still be down. Such a release ends a hold but fires nothing a real one would (Hold).
    let deviceGone: Bool

    init(code: UInt8, isDown: Bool, deviceGone: Bool = false) {
        self.code = code
        self.isDown = isDown
        self.deviceGone = deviceGone
    }
}

/// HID input report 4 of a mouse in driver mode: an array of the private keys held now, all
/// zero for none. Pure, so the layout is tested without a mouse.
enum PrivateKeyReport {
    static let reportID = 4

    /// The keys held, or nil for any other report. IOKit hands the report over with its id
    /// in front, and on the Cobra HyperSpeed over Bluetooth with the id twice
    /// (`04 04 d2 00 00 00 00 00 00`), so up to two leading ids are dropped. A key whose code
    /// is the report id itself can't be told from that, and is never one MacRazer acts on.
    static func heldKeys(reportID: Int, bytes: [UInt8]) -> Set<UInt8>? {
        guard reportID == Self.reportID else { return nil }
        let id = UInt8(Self.reportID)
        var keys = bytes[...]
        if keys.first == id { keys = keys.dropFirst() }
        if keys.first == id { keys = keys.dropFirst() }
        return Set(keys.filter { $0 != 0 })
    }
}

/// A notification the mouse sends by itself in HID input report 5, as the Cobra HyperSpeed
/// does over Bluetooth: a code, then what goes with it. The codes come from other projects'
/// notes and a trace of the Cobra. They are matched on but not relied on: any other is `other`,
/// and nothing depends on one arriving.
enum MouseNotice: Equatable, Sendable {
    /// `02`: the DPI changed, to `x` and `y` (big-endian after the code), nil where the report
    /// is too short to say. In driver mode only MacRazer should change it.
    case dpiChanged(x: Int?, y: Int?)
    /// `09`: availability, with the byte after the code. The Cobra sent `09 02` as it went to
    /// sleep; `09 03` is documented as the wake.
    case availability(UInt8?)
    /// `0c`: power or connection state. The Cobra sent it as it finished starting after a wake.
    case powerState
    /// `10`: a Bluetooth heartbeat.
    case heartbeat
    /// `31`: the battery.
    case battery
    case other(UInt8)

    var code: UInt8 {
        switch self {
        case .dpiChanged: 0x02
        case .availability: 0x09
        case .powerState: 0x0C
        case .heartbeat: 0x10
        case .battery: 0x31
        case .other(let code): code
        }
    }

    /// For the trace.
    var name: String {
        switch self {
        case .dpiChanged(let x, let y): "DPI changed to \(x.map(String.init) ?? "?") x \(y.map(String.init) ?? "?")"
        case .availability(let state): "availability" + (state.map { String(format: " %02x", $0) } ?? "")
        case .powerState: "power state"
        case .heartbeat: "heartbeat"
        case .battery: "battery"
        case .other: "unknown"
        }
    }

    /// With driver mode engaged, whether this suggests the firmware restarted (`powerState`,
    /// `availability`) or acted on the DPI button itself (`dpiChanged`), and so lost the mode
    /// (`DpiDriverModeBook.noticed`). The rest say nothing about it.
    var suggestsModeLost: Bool {
        switch self {
        case .dpiChanged, .availability, .powerState: true
        case .heartbeat, .battery, .other: false
        }
    }
}

/// HID input report 5: the mouse's notifications (`MouseNotice`). Pure, so the layout is
/// tested without a mouse.
enum MouseNoticeReport {
    static let reportID = 5

    /// The notification in a report, or nil for any other report or one with nothing after its
    /// ids. As with report 4 (`PrivateKeyReport`), IOKit hands it over with its id in front,
    /// and on the Cobra over Bluetooth with the id twice (`05 05 09 02 01 ...`), so up to two
    /// leading ids are dropped. A code equal to the id can't be told from that, and is never
    /// one MacRazer acts on.
    static func notice(reportID: Int, bytes: [UInt8]) -> MouseNotice? {
        guard reportID == Self.reportID else { return nil }
        let id = UInt8(Self.reportID)
        var rest = bytes[...]
        if rest.first == id { rest = rest.dropFirst() }
        if rest.first == id { rest = rest.dropFirst() }
        guard let code = rest.first else { return nil }
        let after = Array(rest.dropFirst())
        func bigEndian(at index: Int) -> Int? {
            after.count >= index + 2 ? Int(after[index]) << 8 | Int(after[index + 1]) : nil
        }
        switch code {
        case 0x02: return .dpiChanged(x: bigEndian(at: 0), y: bigEndian(at: 2))
        case 0x09: return .availability(after.first)
        case 0x0C: return .powerState
        case 0x10: return .heartbeat
        case 0x31: return .battery
        default: return .other(code)
        }
    }
}

/// Turns the successive key arrays of report 4 into a down and an up per key. A frame that
/// holds what the last one held changes nothing.
///
/// The mouse matches as two HID devices, and each delivers every frame. Those copies don't
/// always alternate: IOKit hands over all of one device's waiting reports at once, so after
/// the main thread was busy for longer than a short press's 55 ms the order is one device's
/// press and release, then the other's, which one shared array would take for two presses.
/// So only one device's frames count (`update(_:from:)`): the first to deliver one, until it
/// goes away (`sourceGone`).
struct PrivateKeyTracker: Equatable, Sendable {
    private(set) var held: Set<UInt8> = []
    /// The device whose frames count, nil until one delivers a frame.
    private(set) var source: Int?

    /// The events from `keys`, the keys held now: releases first, then presses, each in code
    /// order so the result never depends on a set's order.
    mutating func update(_ keys: Set<UInt8>) -> [PrivateKeyEvent] {
        let released = held.subtracting(keys).sorted().map { PrivateKeyEvent(code: $0, isDown: false) }
        let pressed = keys.subtracting(held).sorted().map { PrivateKeyEvent(code: $0, isDown: true) }
        held = keys
        return released + pressed
    }

    /// The same for a frame from the HID device `source`. Nothing for a frame from any device
    /// but the one whose frames count.
    mutating func update(_ keys: Set<UInt8>, from source: Int) -> [PrivateKeyEvent] {
        if self.source == nil { self.source = source }
        guard self.source == source else { return [] }
        return update(keys)
    }

    /// The HID device `source` went away. If its frames were the ones counting, what it held
    /// comes up, as no release will come from it now (the mouse disconnected, most often),
    /// marked `deviceGone`, and the next device to deliver a frame counts.
    mutating func sourceGone(_ source: Int) -> [PrivateKeyEvent] {
        guard self.source == source else { return [] }
        self.source = nil
        return update([]).map { PrivateKeyEvent(code: $0.code, isDown: $0.isDown, deviceGone: true) }
    }
}

/// Where `ButtonRemapper` gets the DPI button's private keys from. The app's is
/// `DpiPrivateKeyWatcher`; tests hand the remapper the keys themselves.
protocol PrivateKeySource: AnyObject {
    var isRunning: Bool { get }
    /// Starts delivering the private keys of the Bluetooth mouse `productID`, and the
    /// notifications it sends in report 5 (`MouseNotice`), on the main thread. False when it
    /// can't: Input Monitoring isn't granted, or the mouse's HID device wouldn't open. Starting
    /// again for the same mouse keeps what is running. A failure isn't kept: the next start
    /// tries again from scratch.
    func start(productID: Int, onEvent: @escaping (PrivateKeyEvent) -> Void,
               onNotice: @escaping (MouseNotice) -> Void) -> Bool
    func stop()
    /// Whether a start for `productID` would open the mouse now, found by opening and closing
    /// it at once: nothing is watched or kept, and nothing is sent to the mouse. How a run
    /// whose start failed finds out that Input Monitoring has come into effect after all.
    func canWatch(productID: Int) -> Bool
}

/// Watches HID input report 4 of one Bluetooth mouse (vendor 0x068E and its product id, so
/// nothing of any other device) and turns it into private-key events (`PrivateKeyTracker`).
/// Needs Input Monitoring, as every HID input read does. Only runs while the mouse is in
/// driver mode, which is when it sends that report. Its report 5 comes through the same
/// callbacks, and is handed on as the mouse's notifications (`MouseNoticeReport`): a sign that
/// the firmware restarted or cycled DPI itself, and may have dropped driver mode. Both of the
/// mouse's HID devices deliver it, so a notification usually comes twice.
///
/// An `IOHIDManager` finds the mouse's HID devices, now and whenever macOS enumerates them
/// again (a reconnect), and each is watched as the gesture trace watches it
/// (`GestureDebugHIDWatch`): its own buffer and an input report callback whose context is
/// that device's entry. All of them feed one tracker, which counts one device's reports
/// (`PrivateKeyTracker.update(_:from:)`), so a report that comes from two of them counts once.
///
/// Main thread only, like the run loop it schedules on. `@unchecked Sendable` states that
/// discipline, the same as `HIDInputWatcher`.
final class DpiPrivateKeyWatcher: PrivateKeySource, @unchecked Sendable {
    private var manager: IOHIDManager?
    private var watched: [Watched] = []
    private var tracker = PrivateKeyTracker()
    private var onEvent: ((PrivateKeyEvent) -> Void)?
    private var onNotice: ((MouseNotice) -> Void)?
    private var productID: Int?
    /// Retained for the manager's C callbacks' context while running, released by `stop()`.
    private var selfContext: UnsafeMutableRawPointer?
    /// Bumped by every start and stop, so events handed off before a stop are dropped.
    private var generation = 0
    /// The id the next device watched gets, for the tracker.
    private var nextSourceID = 0

    /// One HID device of the mouse, and the buffer its reports land in, kept until it goes.
    /// The context of its input report callback, so a report says which device it came from.
    private final class Watched: @unchecked Sendable {
        let device: IOHIDDevice
        let id: Int
        let buffer: UnsafeMutablePointer<UInt8>
        let size: Int
        /// Weak: the watcher keeps its entries, not the other way round.
        weak var watcher: DpiPrivateKeyWatcher?

        init(device: IOHIDDevice, id: Int, size: Int, watcher: DpiPrivateKeyWatcher) {
            self.device = device
            self.id = id
            self.size = size
            self.watcher = watcher
            buffer = .allocate(capacity: size)
        }

        deinit { buffer.deallocate() }
    }

    var isRunning: Bool { manager != nil }

    /// Whether a start opened the mouse, from what IOKit said: `managerOpen` the manager's own
    /// open, `present` how many of the mouse's HID devices are there, `opened` how many of
    /// them opened. Any one open is a watch that works. With none there, a manager that opened
    /// is waiting for the mouse to show up, and the matching callback brings it; one refused
    /// (kIOReturnNotPermitted: Input Monitoring not in effect for this run) would never see a
    /// report, so that is a failure too, not a watch that silently delivers nothing.
    static func startWorks(managerOpen: IOReturn, present: Int, opened: Int) -> Bool {
        opened > 0 || (present == 0 && managerOpen == kIOReturnSuccess)
    }

    private static func matching(productID: Int) -> CFDictionary {
        [kIOHIDVendorIDKey: BLEProtocol.vendorId, kIOHIDProductIDKey: productID] as CFDictionary
    }

    func canWatch(productID: Int) -> Bool {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return false }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, Self.matching(productID: productID))
        let managerOpen = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        let present = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        var opened = 0
        for device in present where IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            opened += 1
        }
        GestureDebugLog.log(String(format: "PRIVKEY open check for product %04x", productID)
                            + ": open=\(HIDDevice.HIDError.hex(managerOpen)), \(opened) of \(present.count) devices opened")
        return Self.startWorks(managerOpen: managerOpen, present: present.count, opened: opened)
    }

    func start(productID: Int, onEvent: @escaping (PrivateKeyEvent) -> Void,
               onNotice: @escaping (MouseNotice) -> Void) -> Bool {
        if isRunning, self.productID == productID {
            self.onEvent = onEvent
            self.onNotice = onNotice
            return true
        }
        stop()
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            GestureDebugLog.log("PRIVKEY watch not started: Input Monitoring is not granted")
            return false
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, Self.matching(productID: productID))
        let context = Unmanaged.passRetained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<DpiPrivateKeyWatcher>.fromOpaque(context).takeUnretainedValue().watch(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<DpiPrivateKeyWatcher>.fromOpaque(context).takeUnretainedValue().unwatch(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        self.productID = productID
        self.onEvent = onEvent
        self.onNotice = onNotice
        selfContext = context
        tracker = PrivateKeyTracker()
        generation &+= 1
        // The devices there now, at once, so a mouse whose device won't open says so here.
        // The matching callback brings the same ones again, and any that come later.
        let present = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        present.forEach(watch)
        GestureDebugLog.log(String(format: "PRIVKEY watch started for product %04x", productID)
                            + ": open=\(HIDDevice.HIDError.hex(opened)), \(watched.count) of \(present.count) devices opened")
        // Nothing of a failed start is kept: the next start makes a new manager and opens again.
        guard Self.startWorks(managerOpen: opened, present: present.count, opened: watched.count) else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        guard let manager else { return }
        for entry in watched { release(entry) }
        watched = []
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        productID = nil
        onEvent = nil
        onNotice = nil
        tracker = PrivateKeyTracker()
        generation &+= 1
        if let context = selfContext {
            selfContext = nil
            Unmanaged<DpiPrivateKeyWatcher>.fromOpaque(context).release()
        }
        GestureDebugLog.log("PRIVKEY watch stopped")
    }

    private func watch(_ device: IOHIDDevice) {
        guard isRunning, !watched.contains(where: { CFEqual($0.device, device) }) else { return }
        let size = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        let open = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard size > 0, open == kIOReturnSuccess else {
            GestureDebugLog.log("PRIVKEY watch can't open a device: open=\(HIDDevice.HIDError.hex(open)) maxInputReport=\(size)")
            return
        }
        nextSourceID &+= 1
        let entry = Watched(device: device, id: nextSourceID, size: size, watcher: self)
        IOHIDDeviceRegisterInputReportCallback(device, entry.buffer, size, { context, _, _, _, reportID, report, length in
            // Pointer movement comes through here too, at the polling rate: only reports 4 and
            // 5 are copied and looked at.
            guard let context, Int(reportID) == PrivateKeyReport.reportID
                    || Int(reportID) == MouseNoticeReport.reportID else { return }
            let entry = Unmanaged<Watched>.fromOpaque(context).takeUnretainedValue()
            entry.watcher?.received(reportID: Int(reportID),
                                    bytes: Array(UnsafeBufferPointer(start: report, count: max(0, length))),
                                    from: entry.id)
        }, Unmanaged.passUnretained(entry).toOpaque())
        watched.append(entry)
    }

    private func unwatch(_ device: IOHIDDevice) {
        guard let index = watched.firstIndex(where: { CFEqual($0.device, device) }) else { return }
        let entry = watched.remove(at: index)
        release(entry)
        // What this device held won't be released by it now.
        deliver(tracker.sourceGone(entry.id))
    }

    /// Stops a device's reports and closes it. Its entry, and with it the buffer, goes on the
    /// next turn of the run loop, never inside IOKit's own call (the removal callback is one).
    private func release(_ entry: Watched) {
        IOHIDDeviceRegisterInputReportCallback(entry.device, entry.buffer, entry.size, nil, nil)
        IOHIDDeviceClose(entry.device, IOOptionBits(kIOHIDOptionsTypeNone))
        DispatchQueue.main.async { withExtendedLifetime(entry) {} }
    }

    /// Inside IOKit's dispatch of the report: the events go to `onEvent` on the next turn of
    /// the run loop, so whatever they lead to (a stop among them) never runs in here.
    private func received(reportID: Int, bytes: [UInt8], from source: Int) {
        guard isRunning else { return }
        if let keys = PrivateKeyReport.heldKeys(reportID: reportID, bytes: bytes) {
            deliver(tracker.update(keys, from: source))
        } else if let notice = MouseNoticeReport.notice(reportID: reportID, bytes: bytes) {
            deliver(notice)
        }
    }

    /// Hands `notice` to `onNotice` the same way (`deliver(_:)`). Each copy goes on: what it
    /// leads to is spaced out there (`DpiDriverModeBook.noticeCheckSpacing`).
    private func deliver(_ notice: MouseNotice) {
        guard isRunning else { return }
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, self.generation == generation else { return }
            self.onNotice?(notice)
        }
    }

    /// Hands `events` to `onEvent` on the next turn of the run loop, unless a stop or another
    /// start comes first.
    private func deliver(_ events: [PrivateKeyEvent]) {
        guard isRunning, !events.isEmpty else { return }
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, self.generation == generation else { return }
            for event in events {
                GestureDebugLog.log(String(format: "PRIVKEY %@ %02x", event.isDown ? "down" : "up", event.code)
                                    + (event.deviceGone ? " (device gone)" : ""))
                self.onEvent?(event)
            }
        }
    }

    deinit { stop() }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CoreGraphics
import Foundation
import IOKit
import Darwin

/// The identity of the HID service that actually produced a scroll event. A continuous
/// scroll flag alone cannot distinguish a Razer wheel from a trackpad or another mouse.
struct ScrollDevice: Equatable, Sendable {
    var vendorID: Int
    var productID: Int
    var name: String = ""
    var bluetooth = false
    var mouseUsage = false

    var isRazerMouse: Bool {
        // Some mouse interfaces list their keyboard collection first. A known mouse PID
        // still identifies those, without admitting a Razer keyboard's scroll controls.
        if vendorID == Razer.vendorId {
            return mouseUsage || RazerDevices.info(pid: productID) != nil
        }
        if bluetooth {
            return HIDDevice.classifyBluetoothMouse(
                vendorID: vendorID, productID: productID, name: name,
                primaryUsageIsMouse: mouseUsage)?.controllablePID != nil
        }
        return false
    }
}

enum ScrollDirection {
    /// Read every representation before writing: changing the line delta makes macOS
    /// recompute the pixel and fixed-point deltas. Restore those from their original values
    /// afterwards so acceleration and fractional movement are preserved.
    static func reverse(_ event: CGEvent) {
        let axes: [(CGEventField, CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2),
        ]
        let values = axes.map { (line, point, fixed) in
            (event.getIntegerValueField(line), event.getIntegerValueField(point), event.getDoubleValueField(fixed))
        }
        for (fields, value) in zip(axes, values) {
            event.setIntegerValueField(fields.0, value: negated(value.0))
            event.setDoubleValueField(fields.2, value: -value.2)
            event.setIntegerValueField(fields.1, value: negated(value.1))
        }
    }

    private static func negated(_ value: Int64) -> Int64 {
        value == .min ? .max : -value
    }
}

/// macOS does not expose a scroll event's sending device through public CGEvent fields.
/// Resolve its underlying HID event using optional system symbols, then look up that
/// sender's IORegistry entry off the callback. Missing metadata always means pass through.
/// Each scroll tap owns a router; only its sender cache is shared with the lookup queue.
final class ScrollEventRouter: @unchecked Sendable {
    private typealias CopyEvent = @convention(c) (CGEvent) -> UnsafeMutableRawPointer?
    private typealias Sender = @convention(c) (UnsafeRawPointer) -> UInt64

    private let handle: UnsafeMutableRawPointer?
    private let copyEvent: CopyEvent?
    private let sender: Sender?
    private let sources = ScrollSources()

    var available: Bool { copyEvent != nil && sender != nil }

    init() {
        let handle = dlopen(nil, RTLD_LAZY)
        self.handle = handle
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        copyEvent = symbol("CGEventCopyIOHIDEvent", as: CopyEvent.self)
        sender = symbol("IOHIDEventGetSenderID", as: Sender.self)
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    @discardableResult
    func reverse(_ event: CGEvent) -> Bool {
        guard let copyEvent, let sender, let hid = copyEvent(event) else { return false }
        defer { Unmanaged<AnyObject>.fromOpaque(hid).release() }
        let id = sender(hid)
        guard id != 0, sources.contains(id) else { return false }
        ScrollDirection.reverse(event)
        return true
    }

    /// Called on the tap thread before installation, never from an event callback.
    func prepare() { sources.prepare() }
}

/// Sender decisions are preloaded before the tap starts. A newly appearing sender is
/// resolved on a separate queue; its events pass through until identification succeeds.
final class ScrollSources: @unchecked Sendable {
    private let lock = NSLock()
    private var known: [UInt64: (matches: Bool, retryAfter: CFAbsoluteTime)] = [:]
    private var pending = Set<UInt64>()
    private let queue = DispatchQueue(label: "com.macrazer.scroll-sources")
    private let resolve: @Sendable (UInt64) -> Bool
    private let retryInterval: TimeInterval

    init(retryInterval: TimeInterval = 1,
         resolve: @escaping @Sendable (UInt64) -> Bool = ScrollSources.resolve) {
        self.retryInterval = retryInterval
        self.resolve = resolve
    }

    func prepare() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDEventService"), &iterator)
                == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS {
                let matches = Self.isRazerMouse(entry)
                lock.lock()
                known[id] = (matches, matches ? .infinity : CFAbsoluteTimeGetCurrent() + retryInterval)
                lock.unlock()
            }
            IOObjectRelease(entry)
        }
    }

    func contains(_ id: UInt64) -> Bool {
        lock.lock()
        if let result = known[id], CFAbsoluteTimeGetCurrent() < result.retryAfter {
            lock.unlock()
            return result.matches
        }
        guard pending.count < 128, pending.insert(id).inserted else { lock.unlock(); return false }
        lock.unlock()
        queue.async { [self] in
            let matches = resolve(id)
            lock.lock()
            // Keep matched mice, but bound unrecognised/virtual sender entries.
            if known.count >= 256 { known = known.filter { $0.value.matches } }
            known[id] = (matches, matches ? .infinity : CFAbsoluteTimeGetCurrent() + retryInterval)
            pending.remove(id)
            lock.unlock()
        }
        return false
    }

    private static func resolve(_ senderID: UInt64) -> Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(senderID))
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        return isRazerMouse(entry)
    }

    private static func isRazerMouse(_ entry: io_registry_entry_t) -> Bool {
        func property(_ key: String) -> Any? {
            IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                           IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        }
        guard let vendor = property("VendorID") as? Int,
              let product = property("ProductID") as? Int else { return false }
        let transport = property("Transport") as? String ?? ""
        return ScrollDevice(vendorID: vendor, productID: product,
                                  name: property("Product") as? String ?? "",
                                  bluetooth: transport.localizedCaseInsensitiveContains("Bluetooth"),
                                  mouseUsage: property("PrimaryUsagePage") as? Int == 1
                                    && property("PrimaryUsage") as? Int == 2).isRazerMouse
    }
}

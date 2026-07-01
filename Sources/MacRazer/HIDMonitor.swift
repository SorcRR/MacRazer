// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import IOKit
import IOKit.hid

/// Watches the IOKit registry for a vendor's HID devices appearing (USB enumerate / dongle
/// plug-in) and terminating (unplug), firing callbacks on the main queue.
///
/// Uses IOKit *service* notifications — it does NOT open the HID device, so it can't
/// interfere with the control-interface open used to actually send commands. This gives
/// instant wired plug/unplug detection; battery polling remains the fallback for the
/// wireless case where the dongle stays present while the mouse sleeps.
final class HIDMonitor: @unchecked Sendable {
    private var port: IONotificationPortRef?
    private var matchedIter: io_iterator_t = 0
    private var terminatedIter: io_iterator_t = 0
    private let onAppear: @Sendable () -> Void
    private let onRemove: @Sendable () -> Void
    /// An extra retain on `self`, held for the IOKit callback context. A callback already
    /// queued on `.main` when the owner drops its reference would otherwise read a deallocated
    /// `self` (the context pointer is unretained-by-default, which doesn't keep `self` alive).
    /// Released by `invalidate()`, which must be called before the owner's last reference goes
    /// away; until then this keeps the object alive deliberately.
    private var selfContext: UnsafeMutableRawPointer?

    init(vendorId: Int, onAppear: @escaping @Sendable () -> Void, onRemove: @escaping @Sendable () -> Void) {
        self.onAppear = onAppear
        self.onRemove = onRemove

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            FileHandle.standardError.write(Data(
                "[MacRazer] IONotificationPortCreate failed — plug/unplug detection disabled, polling only\n".utf8))
            return
        }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)

        let ctx = Unmanaged.passRetained(self).toOpaque()
        selfContext = ctx

        let matchedCB: IOServiceMatchingCallback = { refcon, iterator in
            HIDMonitor.drain(iterator)
            if let refcon { Unmanaged<HIDMonitor>.fromOpaque(refcon).takeUnretainedValue().onAppear() }
        }
        let terminatedCB: IOServiceMatchingCallback = { refcon, iterator in
            HIDMonitor.drain(iterator)
            if let refcon { Unmanaged<HIDMonitor>.fromOpaque(refcon).takeUnretainedValue().onRemove() }
        }

        func matchingDict() -> CFDictionary {
            let d = (IOServiceMatching("IOHIDDevice") as NSMutableDictionary)
            d[kIOHIDVendorIDKey] = vendorId
            return d as CFDictionary
        }

        // Log registration failures: a silently dead monitor just degrades plug/unplug
        // detection to the poll fallback, which would otherwise be indistinguishable from
        // "working" while masking the real problem.
        let matchedResult = IOServiceAddMatchingNotification(
            port, kIOMatchedNotification, matchingDict(), matchedCB, ctx, &matchedIter)
        if matchedResult == kIOReturnSuccess {
            HIDMonitor.drain(matchedIter) // arm the notification + consume currently-present devices
        } else {
            FileHandle.standardError.write(Data(
                "[MacRazer] HID matched-notification registration failed: 0x\(String(UInt32(bitPattern: matchedResult), radix: 16))\n".utf8))
        }

        let terminatedResult = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, matchingDict(), terminatedCB, ctx, &terminatedIter)
        if terminatedResult == kIOReturnSuccess {
            HIDMonitor.drain(terminatedIter) // arm
        } else {
            FileHandle.standardError.write(Data(
                "[MacRazer] HID terminated-notification registration failed: 0x\(String(UInt32(bitPattern: terminatedResult), radix: 16))\n".utf8))
        }
    }

    /// Consume (and release) all io_objects an iterator currently holds. Required to re-arm
    /// the notification; on the initial call it just absorbs the already-present devices.
    private static func drain(_ iterator: io_iterator_t) {
        var obj = IOIteratorNext(iterator)
        while obj != 0 {
            IOObjectRelease(obj)
            obj = IOIteratorNext(iterator)
        }
    }

    /// Stops IOKit notifications and releases the retained callback context. Must be called by
    /// the owner before dropping its last reference — until this runs, the retain in `init`
    /// keeps this object alive on purpose, so `deinit` is only ever reached afterward.
    func invalidate() {
        if let port { IONotificationPortDestroy(port) }
        port = nil
        if matchedIter != 0 { IOObjectRelease(matchedIter); matchedIter = 0 }
        if terminatedIter != 0 { IOObjectRelease(terminatedIter); terminatedIter = 0 }
        if let ctx = selfContext {
            selfContext = nil
            Unmanaged<HIDMonitor>.fromOpaque(ctx).release()
        }
    }

    deinit {
        // Reached only after `invalidate()` already ran (it holds the only retain that would
        // otherwise prevent deinit), so this is a no-op safety net, not the primary teardown.
        if matchedIter != 0 { IOObjectRelease(matchedIter) }
        if terminatedIter != 0 { IOObjectRelease(terminatedIter) }
        if let port { IONotificationPortDestroy(port) }
    }
}

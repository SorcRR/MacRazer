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

    init(vendorId: Int, onAppear: @escaping @Sendable () -> Void, onRemove: @escaping @Sendable () -> Void) {
        self.onAppear = onAppear
        self.onRemove = onRemove

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)

        let ctx = Unmanaged.passUnretained(self).toOpaque()

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

        IOServiceAddMatchingNotification(port, kIOMatchedNotification, matchingDict(), matchedCB, ctx, &matchedIter)
        HIDMonitor.drain(matchedIter) // arm the notification + consume currently-present devices

        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matchingDict(), terminatedCB, ctx, &terminatedIter)
        HIDMonitor.drain(terminatedIter) // arm
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

    deinit {
        if matchedIter != 0 { IOObjectRelease(matchedIter) }
        if terminatedIter != 0 { IOObjectRelease(terminatedIter) }
        if let port { IONotificationPortDestroy(port) }
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import IOKit
import IOKit.hid

/// Waits for the mouse itself to say something: a movement, a click, a wheel tick. Those
/// arrive as HID input reports, and macOS delivers them to any process with Input Monitoring
/// without taking the device away from the system, so the pointer keeps working normally.
///
/// This is the one thing the OS will tell us about a wireless mouse that the dongle won't. A
/// mouse asleep behind its dongle looks exactly like a mouse that is off: the dongle stays
/// enumerated and answers commands on its behalf with a timeout, and no notification fires
/// when the mouse comes back. Polling is the fallback for that, and it deliberately backs off
/// while the mouse stays away (see `BatteryPollStateMachine.Cadence`) — so without this, a
/// mouse that woke up sat unnoticed until the next poll.
///
/// Reports follow movement, so silence proves nothing and this never reports a disconnect.
/// It is a wake-up signal only, and a coarse one: it fires for any Razer mouse, so the caller
/// treats it as "look now", never as "the mouse is back". The battery read that follows is
/// what decides.
///
/// Only run while the mouse is unreachable. A mouse in use produces a hundred or more reports
/// a second, and waking this process for each of them would cost far more than the polling
/// this app just stopped doing.
///
/// Main thread only, like the run loop it schedules on: IOKit delivers the reports there
/// because that is the run loop the devices are scheduled on, and every method is called from
/// there too. `@unchecked Sendable` states that discipline, the same as `HIDMonitor`.
final class HIDInputWatcher: @unchecked Sendable {
    private let vendorId: Int
    private let onInput: @Sendable () -> Void
    private var open: [(device: IOHIDDevice, buffer: UnsafeMutablePointer<UInt8>, size: Int)] = []
    /// Retained for the C callback's context, released by `stop()` — the same rule as
    /// `HIDMonitor`: an unretained context pointer does not keep this object alive.
    private var selfContext: UnsafeMutableRawPointer?
    /// A report has arrived and the hand-off is already scheduled. The rest of the burst is
    /// ignored rather than queueing a check per movement.
    private var fired = false

    init(vendorId: Int, onInput: @escaping @Sendable () -> Void) {
        self.vendorId = vendorId
        self.onInput = onInput
    }

    var isRunning: Bool { selfContext != nil }

    /// Opens every Razer mouse interface and listens. A device that can't be opened is
    /// skipped: without Input Monitoring this does nothing at all, and polling still covers
    /// the reconnect, just more slowly.
    func start() {
        guard !isRunning else { return }
        fired = false
        let context = Unmanaged.passRetained(self).toOpaque()

        // Mouse interfaces only (Generic Desktop / Mouse). A Razer keyboard on the same
        // vendor id says nothing about this mouse.
        let devices = HIDDevice.devices(matching: [
            kIOHIDVendorIDKey as String: vendorId,
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse,
        ])
        var opened: [(device: IOHIDDevice, buffer: UnsafeMutablePointer<UInt8>, size: Int)] = []
        for device in devices {
            let size = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
            guard size > 0,
                  IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
            else { continue }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { context, _, _, _, _, _, _ in
                guard let context else { return }
                Unmanaged<HIDInputWatcher>.fromOpaque(context).takeUnretainedValue().report()
            }, context)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            opened.append((device, buffer, size))
        }
        // Nothing opened means nothing is listening, so this is not running and the next
        // start must be free to try again: no device matched (the dongle is out), or Input
        // Monitoring has not been granted yet and may be in a moment.
        guard !opened.isEmpty else {
            Unmanaged<HIDInputWatcher>.fromOpaque(context).release()
            return
        }
        open = opened
        selfContext = context
    }

    /// Stops listening and closes everything. Safe to call when not running.
    func stop() {
        for entry in open {
            IOHIDDeviceRegisterInputReportCallback(entry.device, entry.buffer, entry.size, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(entry.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(entry.device, IOOptionBits(kIOHIDOptionsTypeNone))
            entry.buffer.deallocate()
        }
        open.removeAll()
        // Any report already handed off belongs to the session being stopped.
        fired = false
        if let context = selfContext {
            selfContext = nil
            Unmanaged<HIDInputWatcher>.fromOpaque(context).release()
        }
    }

    /// One report is all it takes; the rest of the burst is dropped, so the movement that
    /// woke the mouse costs one hand-off rather than a hundred a second. The caller starts
    /// this again if the check that follows still finds nothing.
    ///
    /// Closing the devices happens on the next run-loop turn, never here: this runs inside
    /// IOKit's own dispatch of the report, and unscheduling and closing a device from inside
    /// its callback — which is what the caller's restart would do too — takes the process
    /// down.
    private func report() {
        guard isRunning, !fired else { return }
        fired = true
        DispatchQueue.main.async { [weak self] in
            // `stop()` in between (the mouse answered a poll meanwhile) cancels this.
            guard let self, self.isRunning, self.fired else { return }
            self.stop()
            self.onInput()
        }
    }

    deinit {
        // Only reached once `stop()` has released the context retain, so there is nothing
        // left open here. Kept as a safety net for a watcher that was never started.
        stop()
    }
}

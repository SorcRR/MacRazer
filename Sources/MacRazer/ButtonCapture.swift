// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import IOKit
import IOKit.hid

/// Listens to one mouse's own inputs during the device test's button step, to record which
/// extra buttons it has and what they send.
///
/// The mouse itself, not the system's event stream: `ButtonRemapper`'s tap can't tell which
/// device a click came from, and would miss side buttons that type keys rather than click,
/// which is how a Naga's 12-button panel works. HID input values from the mouse's own
/// interfaces carry both, and need only the Input Monitoring the app already has.
///
/// Only runs while the step is open. Left and right clicks are ignored (the person is using
/// this mouse to press Next), as are movement and the wheel.
///
/// Main thread only, like the run loop it schedules on. `@unchecked Sendable` states that
/// discipline, the same as `HIDInputWatcher`.
final class ButtonCapture: @unchecked Sendable {
    private let onInput: @Sendable (String) -> Void
    private var open: [IOHIDDevice] = []
    /// Retained for the C callback's context, released by `stop()`.
    private var selfContext: UnsafeMutableRawPointer?

    init(onInput: @escaping @Sendable (String) -> Void) {
        self.onInput = onInput
    }

    var isRunning: Bool { selfContext != nil }

    /// Opens every interface of the given mouse that sends input and listens. Returns whether
    /// anything opened: without Input Monitoring, or with the mouse gone, nothing does, and the
    /// step should say so rather than wait for presses that can't arrive.
    @discardableResult
    func start(vendorID: Int, productID: Int) -> Bool {
        guard !isRunning else { return true }
        let context = Unmanaged.passRetained(self).toOpaque()
        var opened: [IOHIDDevice] = []
        for device in HIDDevice.devices(matching: [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
        ]) {
            let size = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
            guard size > 0,
                  IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
            else { continue }
            IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
                guard let context else { return }
                let element = IOHIDValueGetElement(value)
                let page = Int(IOHIDElementGetUsagePage(element))
                let usage = Int(IOHIDElementGetUsage(element))
                guard let label = ButtonCapture.label(page: page, usage: usage,
                                                      value: IOHIDValueGetIntegerValue(value)) else { return }
                Unmanaged<ButtonCapture>.fromOpaque(context).takeUnretainedValue().onInput(label)
            }, context)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            opened.append(device)
        }
        guard !opened.isEmpty else {
            Unmanaged<ButtonCapture>.fromOpaque(context).release()
            return false
        }
        open = opened
        selfContext = context
        return true
    }

    func stop() {
        for device in open {
            IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        open.removeAll()
        if let context = selfContext {
            selfContext = nil
            Unmanaged<ButtonCapture>.fromOpaque(context).release()
        }
    }

    /// Which inputs count, as "page:usage" in hex: a press (nonzero value) of a mouse button
    /// other than left and right, a keyboard key, or a consumer control such as a media key.
    /// Everything else (movement, the wheel, releases) is nil.
    static func label(page: Int, usage: Int, value: Int) -> String? {
        guard value != 0 else { return nil }
        switch page {
        case kHIDPage_Button where usage >= 3,
             kHIDPage_KeyboardOrKeypad where (0x04...0xE7).contains(usage),
             kHIDPage_Consumer where usage != 0:
            return String(format: "%02x:%02x", page, usage)
        default:
            return nil
        }
    }

    /// A name a person would recognise, for the step's list: "Button 4", "Key 1", "Media key".
    static func friendlyName(_ label: String) -> String {
        let parts = label.split(separator: ":").compactMap { Int($0, radix: 16) }
        guard parts.count == 2 else { return label }
        let (page, usage) = (parts[0], parts[1])
        switch page {
        case kHIDPage_Button: return "Button \(usage)"
        case kHIDPage_KeyboardOrKeypad:
            switch usage {
            case 0x04...0x1D: return "Key " + String(UnicodeScalar(UInt8(usage - 0x04) + 65))
            case 0x1E...0x26: return "Key \(usage - 0x1D)"
            case 0x27: return "Key 0"
            case 0x2D: return "Key -"
            case 0x2E: return "Key ="
            default: return "Key \(label)"
            }
        case kHIDPage_Consumer: return "Media key"
        default: return label
        }
    }

    deinit { stop() }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// BLE GATT framing used by the Basilisk V3 X HyperSpeed (BT PID 0x00BA).
/// This is intentionally separate from the 90-byte USB HID report codec.
enum BLEVendorProtocol {
    static let serviceUUID = "52401523-F97C-7F90-0E7F-6C6F4E36DB1C"
    static let writeUUID = "52401524-F97C-7F90-0E7F-6C6F4E36DB1C"
    static let notifyUUID = "52401525-F97C-7F90-0E7F-6C6F4E36DB1C"

    struct Key: Equatable {
        let bytes: [UInt8]
        init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) { bytes = [a, b, c, d] }
    }

    static let battery = Key(0x05, 0x81, 0x00, 0x01)
    static let sleepTimeoutGet = Key(0x05, 0x84, 0x00, 0x00)
    static let dpiStagesGet = Key(0x0B, 0x84, 0x01, 0x00)
    static let dpiStagesSet = Key(0x0B, 0x04, 0x01, 0x00)
    static let brightnessGet = Key(0x10, 0x85, 0x01, 0x01)
    static let brightnessSet = Key(0x10, 0x05, 0x01, 0x00)
    static let colorSet = Key(0x10, 0x04, 0x00, 0x00)
    // Reads target the active hardware bank (target 0); writes use projection bank 1.
    static let buttonBindingGet = Key(0x08, 0x84, 0x00, 0x60)
    static let buttonBindingSet = Key(0x08, 0x04, 0x01, 0x60)

    enum DPIButtonBinding: Equatable, Identifiable, Sendable {
        case dpiCycle
        case leftClick
        case rightClick
        case middleClick
        case back
        case forward
        case scrollUp
        case scrollDown
        case keyboardShortcut(hidUsage: UInt8, modifiers: UInt8)

        /// Direct mouse actions. Media and Double Click use softwareBridge plus the
        /// existing macOS remapper; no undocumented consumer-control payload is sent.
        static let allCases: [Self] = [
            .dpiCycle, .leftClick, .rightClick, .middleClick, .back, .forward, .scrollUp, .scrollDown,
        ]

        static let softwareBridge: Self = .keyboardShortcut(hidUsage: 0x6F, modifiers: 0)

        var id: String {
            switch self {
            case .keyboardShortcut(let usage, let modifiers): return "keyboard-\(usage)-\(modifiers)"
            default: return label
            }
        }

        var label: String {
            switch self {
            case .dpiCycle: return "DPI Cycle (default)"
            case .leftClick: return "Left Click"
            case .rightClick: return "Right Click"
            case .middleClick: return "Middle Click"
            case .back: return "Back"
            case .forward: return "Forward"
            case .scrollUp: return "Scroll Up"
            case .scrollDown: return "Scroll Down"
            case .keyboardShortcut(let usage, let modifiers):
                return "Shortcut \(BLEVendorProtocol.shortcutLabel(hidUsage: usage, modifiers: modifiers))"
            }
        }

        var buttonID: UInt8? {
            switch self {
            case .leftClick: return 0x01
            case .rightClick: return 0x02
            case .middleClick: return 0x03
            case .back: return 0x04
            case .forward: return 0x05
            case .scrollUp: return 0x09
            case .scrollDown: return 0x0A
            case .dpiCycle, .keyboardShortcut: return nil
            }
        }

        var keyboardPayload: [UInt8]? {
            guard case .keyboardShortcut(let usage, let modifiers) = self else { return nil }
            // Seven-byte function block: keyboard action, key-function type, modifier, HID key.
            return [0x02, 0x02, modifiers, usage, 0, 0, 0]
        }
    }

    static func readHeader(request: UInt8, key: Key) -> Data {
        Data([request, 0, 0, 0] + key.bytes)
    }

    static func writeFrames(request: UInt8, key: Key, payload: Data) -> [Data] {
        var result = [Data([request, UInt8(payload.count), 0, 0] + key.bytes)]
        var offset = 0
        while offset < payload.count {
            let end = min(offset + 20, payload.count)
            result.append(payload.subdata(in: offset..<end))
            offset = end
        }
        return result
    }

    static func dpiButtonPayload(for binding: DPIButtonBinding) -> Data {
        if let keyboard = binding.keyboardPayload {
            return Data([0x01, 0x60, 0x00] + keyboard)
        }
        if let buttonID = binding.buttonID {
            return Data([0x01, 0x60, 0x00, 0x01, 0x01, buttonID, 0, 0, 0, 0])
        }
        return Data([0x01, 0x60, 0x00, 0x06, 0x01, 0x06, 0, 0, 0, 0])
    }

    static func parseDpiButtonBinding(_ payload: Data) throws -> DPIButtonBinding {
        let bytes = Array(payload)
        let functionBlock: [UInt8]
        if bytes.count >= 10, bytes[0] == 0x01, bytes[1] == 0x60 {
            functionBlock = Array(bytes[3..<10])
        } else if bytes.count >= 16, bytes[0] == 0x60 {
            let packed = Array(bytes.dropFirst(2))
            functionBlock = Array(packed.enumerated().compactMap { index, byte in
                index.isMultiple(of: 2) ? byte : nil
            }.prefix(7))
        } else {
            throw HIDDevice.HIDError.badResponse
        }

        if functionBlock == [0x06, 0x01, 0x06, 0, 0, 0, 0] { return .dpiCycle }
        if functionBlock.count == 7, functionBlock[0] == 0x02, functionBlock[1] == 0x02,
           functionBlock[4...6].allSatisfy({ $0 == 0 }), functionBlock[3] != 0 {
            return .keyboardShortcut(hidUsage: functionBlock[3], modifiers: functionBlock[2])
        }
        guard functionBlock.count == 7,
              functionBlock[0] == 0x01,
              functionBlock[1] == 0x01,
              let binding = DPIButtonBinding.allCases.first(where: { $0.buttonID == functionBlock[2] }) else {
            throw HIDDevice.HIDError.notSupported
        }
        return binding
    }

    /// Translate macOS virtual key codes from the existing recorder/preset catalog into
    /// USB keyboard usages used by the Basilisk BLE protocol. Unknown keys fail closed.
    static func hidUsage(forMacKeyCode keyCode: UInt16) -> UInt8? {
        let map: [UInt16: UInt8] = [
            0: 0x04, 1: 0x16, 2: 0x07, 3: 0x09, 4: 0x0B, 5: 0x0A,
            6: 0x1D, 7: 0x1B, 8: 0x06, 9: 0x19, 11: 0x05, 12: 0x14,
            13: 0x1A, 14: 0x08, 15: 0x15, 16: 0x1C, 17: 0x17,
            18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 22: 0x23,
            23: 0x22, 25: 0x26, 26: 0x24, 28: 0x25, 29: 0x27,
            24: 0x2E, 27: 0x2D, 30: 0x30, 31: 0x12, 32: 0x18, 33: 0x2F,
            34: 0x0C, 35: 0x13, 36: 0x28, 37: 0x0F, 38: 0x0D, 39: 0x34,
            40: 0x0E, 41: 0x33, 42: 0x31, 43: 0x36, 44: 0x38, 45: 0x11,
            46: 0x10, 47: 0x37, 48: 0x2B, 49: 0x2C, 50: 0x35, 51: 0x2A,
            53: 0x29, 76: 0x58, 115: 0x4A, 116: 0x4B, 117: 0x4C, 119: 0x4D,
            121: 0x4E, 123: 0x50, 124: 0x4F, 125: 0x51, 126: 0x52,
        ]
        return map[keyCode]
    }

    static func macKeyCode(forHIDUsage usage: UInt8) -> UInt16? {
        // Reverse the one-to-one subset above. Duplicate navigation aliases resolve to the
        // standard extended-key codes used by KeyRecorderView.
        switch usage {
        case 0x4A: return 115; case 0x4B: return 116; case 0x4D: return 119; case 0x4E: return 121
        default:
            for code in UInt16(0)...126 {
                if hidUsage(forMacKeyCode: code) == usage { return code }
            }
            return nil
        }
    }

    static func shortcutLabel(hidUsage: UInt8, modifiers: UInt8) -> String {
        var label = ""
        if modifiers & 0x01 != 0 { label += "⌃" }
        if modifiers & 0x04 != 0 { label += "⌥" }
        if modifiers & 0x02 != 0 { label += "⇧" }
        if modifiers & 0x08 != 0 { label += "⌘" }
        let key: String
        switch hidUsage {
        case 0x04...0x1D:
            let letters = ["A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z"]
            key = letters[Int(hidUsage - 0x04)]
        case 0x1E...0x27:
            key = ["1","2","3","4","5","6","7","8","9","0"][Int(hidUsage - 0x1E)]
        case 0x28: key = "↩"; case 0x29: key = "⎋"; case 0x2A: key = "⌫"
        case 0x2B: key = "⇥"; case 0x2C: key = "Space"; case 0x2D: key = "-"
        case 0x2E: key = "="; case 0x2F: key = "["; case 0x30: key = "]"
        case 0x31: key = "\\"; case 0x33: key = ";"; case 0x34: key = "'"
        case 0x35: key = "`"; case 0x36: key = ","; case 0x37: key = "."; case 0x38: key = "/"
        case 0x45: key = "F12"
        case 0x6F: key = "F20"
        case 0x4C: key = "⌦"; case 0x4F: key = "→"; case 0x50: key = "←"
        case 0x51: key = "↓"; case 0x52: key = "↑"
        default: key = "Key 0x\(String(hidUsage, radix: 16, uppercase: true))"
        }
        return label + key
    }

    /// Resolve the matching response header and concatenate its continuation frames.
    static func payload(from notifications: [Data], request: UInt8) throws -> Data {
        guard let index = notifications.firstIndex(where: {
            $0.count >= 8 && $0[0] == request && [0x02, 0x03, 0x05].contains($0[7])
        }) else { throw HIDDevice.HIDError.timeout }
        let header = notifications[index]
        switch header[7] {
        case 0x02: break
        case 0x05: throw HIDDevice.HIDError.notSupported
        default: throw HIDDevice.HIDError.commandFailed
        }
        let length = Int(header[1])
        guard length > 0 else { return Data() }
        var bytes = Data()
        if index + 1 < notifications.count {
            for frame in notifications[(index + 1)...] { bytes.append(frame) }
        } else {
            bytes.append(header.dropFirst(8))
        }
        guard bytes.count >= length else { throw HIDDevice.HIDError.badResponse }
        return Data(bytes.prefix(length))
    }

    struct DpiSnapshot: Equatable {
        var active: Int
        var stageIDs: [UInt8]
        var values: [Int]
        var slots: [Int]
        var marker: UInt8
    }

    static func parseDpiStages(_ payload: Data) throws -> DpiSnapshot {
        let bytes = Array(payload)
        guard bytes.count >= 9 else { throw HIDDevice.HIDError.badResponse }
        let count = Int(bytes[1])
        guard (1...5).contains(count) else { throw HIDDevice.HIDError.badResponse }
        var ids: [UInt8] = []
        var values: [Int] = []
        var marker: UInt8 = 0x03
        for i in 0..<count {
            let base = 2 + i * 7
            // Some Basilisk V3 X replies omit the final entry's marker byte. Its stage ID
            // and both DPI axes must still be present; the missing reserved byte is optional.
            guard bytes.count >= base + 5 else { throw HIDDevice.HIDError.badResponse }
            ids.append(bytes[base])
            values.append(Int(bytes[base + 1]) | (Int(bytes[base + 2]) << 8))
            if i == count - 1, bytes.indices.contains(base + 6) { marker = bytes[base + 6] }
        }
        let activeRaw = Int(bytes[0])
        let active = ids.firstIndex(of: UInt8(activeRaw)) ?? max(0, min(count - 1, activeRaw > 0 ? activeRaw - 1 : 0))
        var slots = values
        while slots.count < 5 { slots.append(slots.last ?? 800) }
        var allIDs = ids
        while allIDs.count < 5 { allIDs.append((allIDs.last ?? 0) &+ 1) }
        return DpiSnapshot(active: active, stageIDs: allIDs, values: values, slots: slots, marker: marker)
    }

    static func parseSleepTimeout(_ payload: Data) throws -> UInt16 {
        guard payload.count >= 2 else { throw HIDDevice.HIDError.badResponse }
        return UInt16(payload[0]) | (UInt16(payload[1]) << 8)
    }

    /// Encode the device-specific BLE DPI stage table, preserving stage IDs from readback.
    static func dpiStagePayload(values: [Int], active: Int, stageIDs: [UInt8],
                                preservedSlots: [Int]? = nil, marker: UInt8 = 0x03) -> Data {
        let newValues = Array(values.prefix(5))
        let count = newValues.count
        let ids = (0..<count).map { $0 < stageIDs.count ? stageIDs[$0] : UInt8($0 + 1) }
        let activeIndex = max(0, min(count - 1, active))
        let activeToken = Int(ids[activeIndex])
        var bytes: [UInt8] = [UInt8(activeToken), UInt8(count)]
        var slots = preservedSlots ?? newValues
        for i in 0..<count {
            if i >= slots.count { slots.append(newValues[i]) }
            else { slots[i] = newValues[i] }
        }
        while slots.count < 5 { slots.append(slots.last ?? newValues.last ?? 800) }
        for i in 0..<5 {
            let value = UInt16(max(100, min(slots[i], 45000)))
            let id = i < stageIDs.count ? stageIDs[i] : UInt8(i + 1)
            bytes += [id, UInt8(value & 0xFF), UInt8(value >> 8), UInt8(value & 0xFF), UInt8(value >> 8), 0, i == 4 ? marker : 0]
        }
        bytes.append(0)
        return Data(bytes)
    }

    static func dpiStages(from report: RazerReport, preserving current: DpiSnapshot?) -> Data {
        let count = max(1, min(5, Int(report.arguments[2])))
        let active = max(0, min(count - 1, Int(report.arguments[1])))
        var values: [Int] = []
        for i in 0..<count {
            let base = 3 + i * 7
            let dpi = (Int(report.arguments[base + 1]) << 8) | Int(report.arguments[base + 2])
            values.append(dpi)
        }
        return dpiStagePayload(values: values, active: active, stageIDs: current?.stageIDs ?? [],
                               preservedSlots: current?.slots, marker: current?.marker ?? 0x03)
    }

    /// Verify a DPI write against a fresh BLE stage-table read. A successful GATT write
    /// acknowledgement only confirms transport delivery; it does not prove the mouse
    /// applied the setting.
    static func verifyDpiReadback(for report: RazerReport, snapshot: DpiSnapshot) throws {
        switch (report.commandClass, report.commandId) {
        case (0x04, 0x05):
            let expected = (Int(report.arguments[1]) << 8) | Int(report.arguments[2])
            guard snapshot.values.indices.contains(snapshot.active), snapshot.values[snapshot.active] == expected else {
                throw HIDDevice.HIDError.commandFailed
            }
        case (0x04, 0x06):
            let count = max(1, min(5, Int(report.arguments[2])))
            let active = max(0, min(count - 1, Int(report.arguments[1])))
            let expected = (0..<count).map { i -> Int in
                let base = 3 + i * 7
                return (Int(report.arguments[base + 1]) << 8) | Int(report.arguments[base + 2])
            }
            guard snapshot.values == expected, snapshot.active == active else {
                throw HIDDevice.HIDError.commandFailed
            }
        default:
            return
        }
    }

    static func syntheticStagesReport(_ snapshot: DpiSnapshot) -> RazerReport {
        var report = RazerReport(commandClass: 0x04, commandId: 0x86, dataSize: 0x26)
        report.status = 0x02
        report.arguments[1] = UInt8(snapshot.active)
        report.arguments[2] = UInt8(snapshot.values.count)
        for i in snapshot.values.indices {
            let base = 3 + i * 7
            let value = UInt16(snapshot.values[i])
            report.arguments[base] = snapshot.stageIDs[i]
            report.arguments[base + 1] = UInt8(value >> 8)
            report.arguments[base + 2] = UInt8(value & 0xFF)
            report.arguments[base + 3] = UInt8(value >> 8)
            report.arguments[base + 4] = UInt8(value & 0xFF)
        }
        return report
    }
}

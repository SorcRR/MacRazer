// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Razer's control protocol over Bluetooth LE: a vendor GATT service, not the 90-byte HID
/// feature report the cable and dongle use. The service, the frame layout and the command
/// keys were reverse-engineered by @ungrav on the Basilisk V3 X HyperSpeed
/// (SorcRR/MacRazer#32); the Cobra HyperSpeed answers the same service byte for byte.
///
/// The app speaks `RazerReport` everywhere, so this file translates: a USB-style request
/// goes in, a BLE request comes out, and the BLE reply is folded back into the USB reply
/// layout the existing parsers in `RazerCommands` already read. Commands with no known BLE
/// equivalent (polling rate, effects other than static) map to `notSupported`.
///
/// Pure functions only. The GATT plumbing lives in `BluetoothDevice`.
enum BLEProtocol {
    static let serviceUUID = "52401523-F97C-7F90-0E7F-6C6F4E36DB1C"
    static let writeUUID = "52401524-F97C-7F90-0E7F-6C6F4E36DB1C"
    static let notifyUUID = "52401525-F97C-7F90-0E7F-6C6F4E36DB1C"
    /// A third characteristic other Razer Bluetooth mice expose (read and notify), purpose
    /// unknown. Only the gesture trace subscribes to it (`GestureDebugLog`).
    static let auxiliaryUUID = "52401526-F97C-7F90-0E7F-6C6F4E36DB1C"
    /// Vendor id the mouse reports over Bluetooth (Device Information PnP ID, and the
    /// IOHID `VendorID`). Not the USB 0x1532.
    static let vendorId = 0x068E

    /// Status byte at index 7 of a reply header.
    enum Status: UInt8 {
        case ok = 0x02
        case failure = 0x03
        case notSupported = 0x05
    }

    /// The 4-byte command key. Byte 0 is the class, byte 1 the command (high bit set for
    /// reads, the usual Razer convention); bytes 2–3 are arguments, e.g. the LED id.
    struct Key: Equatable {
        let bytes: [UInt8]
        init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) { bytes = [a, b, c, d] }

        static let battery = Key(0x05, 0x81, 0x00, 0x01)
        static let serial = Key(0x01, 0x83, 0x00, 0x00)
        static let dpiStagesGet = Key(0x0B, 0x84, 0x01, 0x00)
        static let dpiStagesSet = Key(0x0B, 0x04, 0x01, 0x00)
        static let powerTimeoutGet = Key(0x05, 0x84, 0x00, 0x00)
        static let powerTimeoutSet = Key(0x05, 0x04, 0x00, 0x00)
        static func brightnessGet(led: UInt8) -> Key { Key(0x10, 0x85, 0x01, led) }
        static func brightnessSet(led: UInt8) -> Key { Key(0x10, 0x05, 0x01, led) }
        static let staticColor = Key(0x10, 0x04, 0x00, 0x00)
        // The DPI button's assignment lives in the mouse's function table, entry 0x60
        // (`RazerDevices.supportsDpiButtonBinding`). Reads target the slot in use (0); writes
        // go to profile slot 1, as the payload's first byte says too. BluetoothDevice writes
        // only while the mouse says slot 1 is the one in use, and reads the entry before
        // every write and again after it, before the UI reports success.
        static let dpiButtonGet = Key(0x08, 0x84, 0x00, 0x60)
        static let dpiButtonSet = Key(0x08, 0x04, 0x01, 0x60)
        /// Any entry of that function table, by its id (the DPI Cycle entry is 0x60).
        /// Slot 0 reads the slot in use; 1-5 read that slot.
        static func buttonFunctionGet(_ id: UInt8, slot: UInt8 = 0x00) -> Key { Key(0x08, 0x84, slot, id) }
        static func buttonFunctionSet(_ id: UInt8, slot: UInt8 = 0x01) -> Key { Key(0x08, 0x04, slot, id) }
        /// The onboard profile slot the mouse is using, as one byte (Basilisk V4 Pro, #55).
        static let activeSlotGet = Key(0x03, 0x82, 0x00, 0x00)
        /// The mouse's device mode, a little-endian u16: `00 00` normal, `03 00` driver
        /// (`DeviceMode`). Written only on a mouse with `RazerDevices.dpiButtonPrivateKeys`.
        static let deviceModeGet = Key(0x01, 0x82, 0x00, 0x00)
        static let deviceModeSet = Key(0x01, 0x02, 0x00, 0x00)

        /// A read, by the usual Razer convention of the command byte's high bit.
        var isRead: Bool { bytes[1] & 0x80 != 0 }
    }

    // MARK: - Device mode

    /// The device modes MacRazer writes, and no others. In `normal` the firmware handles its
    /// special buttons itself (the Cobra's DPI button cycles DPI); in `driver` it reports them
    /// to the host instead, as private keys in HID input report 4
    /// (`RazerDevices.dpiButtonPrivateKeys`), and leaves acting on them to the host. Driver
    /// mode doesn't last: the mouse is back in normal mode after it sleeps, reconnects or is
    /// switched off and on.
    enum DeviceMode: UInt8, Equatable, Sendable {
        case normal = 0x00
        case driver = 0x03

        /// The u16 a read of the mode answers with for this mode (`parseDeviceMode`).
        var value: UInt16 { UInt16(rawValue) }
    }

    /// The one device-mode write: `01 02 00 00` with `[mode, 0]`. Built only from a
    /// `DeviceMode`, so no other mode, and no other class 01 key, can be written this way.
    static func deviceModeRequest(_ mode: DeviceMode) -> Request {
        Request(key: .deviceModeSet, payload: [mode.rawValue, 0x00], reply: .ack)
    }

    /// The read of the mode: `01 82 00 00`, no payload.
    static let deviceModeReadRequest = Request(key: .deviceModeGet, payload: [], reply: .ack)

    /// The mode a read answers with, the little-endian u16 its payload starts with (`03 00`
    /// is driver mode, 3). Nil when the payload is too short to hold one.
    static func parseDeviceMode(_ payload: some Collection<UInt8>) -> UInt16? {
        let bytes = Array(payload.prefix(2))
        guard bytes.count == 2 else { return nil }
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    /// Why a change of the device mode didn't go through (`BluetoothDevice.setDeviceMode`).
    enum DeviceModeError: Error, Equatable {
        /// The read before the write failed or made no sense, so nothing was written.
        case unreadable
        /// The mouse refused the write or didn't answer it, so it may or may not have taken it.
        case notTaken
        /// The read after the write failed (nil), or showed another mode.
        case notReadBack(UInt16?)
    }

    // MARK: - Gesture trace (diagnostic only)

    /// A read for the trace, or nil for a key that isn't one (`Key.isRead`): the trace's
    /// probes can't write anything by accident.
    static func traceReadRequest(_ key: Key) -> Request? {
        key.isRead ? Request(key: key, payload: [], reply: .ack) : nil
    }

    /// The trace's read-only probes, in the order they run once per connection: the device
    /// mode, the class 01 command catalogue, the button inventory and every binding, the DPI
    /// button's entry (0x60) in the slot in use and in slots 1-5, entry 0x80 (slot in use and
    /// slot 1), the profile slot in use, and the live DPI.
    static let traceProbeKeys: [Key] = [
        .deviceModeGet,
        Key(0x01, 0x80, 0x00, 0x00),
        Key(0x08, 0x80, 0x00, 0x00),
        Key(0x08, 0x80, 0x01, 0x00),
        Key(0x08, 0x83, 0x01, 0x00),
    ] + (0...5).map { Key(0x08, 0x84, UInt8($0), 0x60) } + [
        Key(0x08, 0x84, 0x00, 0x80),
        Key(0x08, 0x84, 0x01, 0x80),
        .activeSlotGet,
        Key(0x0B, 0x81, 0x00, 0x00),
    ]

    /// A reply as the trace records it, kept whole where `Assembler` keeps what the app needs:
    /// the header frame as it came, the length as the 24-bit little-endian value other
    /// implementations read from bytes 1-3 (`Assembler` reads byte 1 only), and every byte of
    /// every continuation frame, past the declared length too.
    ///
    /// Some Razer firmware answers status 03 and then 02 for the same request. So a complete
    /// reply that isn't a success gives way to a later header with the same id, and the status
    /// it had is kept in `replacedStatuses`. `BluetoothDevice` waits a moment for that before
    /// it reports a refusal.
    struct TraceAssembler: Sendable {
        let id: UInt8
        private(set) var header: [UInt8]?
        private(set) var payload: [UInt8] = []
        private(set) var replacedStatuses: [UInt8] = []

        init(id: UInt8) { self.id = id }

        var status: UInt8? { header.map { $0[7] } }
        var declaredLength: Int {
            header.map { Int($0[1]) | Int($0[2]) << 8 | Int($0[3]) << 16 } ?? 0
        }
        var isComplete: Bool { header != nil && payload.count >= declaredLength }
        var isSuccess: Bool { isComplete && status == Status.ok.rawValue }

        /// Whether the frame belongs to this reply. A frame that doesn't (another id before
        /// the header, anything after a successful reply) is the caller's to report.
        @discardableResult
        mutating func add(_ frame: Data) -> Bool {
            let bytes = Array(frame)
            let isHeader = bytes.count >= 8 && bytes[0] == id
            if header == nil || (isComplete && !isSuccess && isHeader) {
                guard isHeader else { return false }
                if let status { replacedStatuses.append(status) }
                header = bytes
                payload = []
                return true
            }
            guard !isComplete else { return false }
            payload += bytes
            return true
        }
    }

    /// One entry of the mouse's function table: what the button does now, and its factory
    /// default. A read answers `id, flag`, then the two 7-byte blocks interleaved byte by byte,
    /// current first (the DPI Cycle parser below reads only the current one). On the
    /// Basilisk V4 Pro a flag of 01 means the entry's HyperShift layer is set, and the second
    /// block is then that layer instead (bthstest, #55, 2026-10-19).
    struct ButtonFunction: Equatable {
        let current: [UInt8]
        let factory: [UInt8]
    }

    static func parseButtonFunction(id: UInt8, _ payload: Data) throws -> ButtonFunction {
        let bytes = Array(payload)
        guard bytes.count >= 16, bytes[0] == id else { throw HIDDevice.HIDError.badResponse }
        let packed = Array(bytes[2..<16])
        return ButtonFunction(current: stride(from: 0, to: 14, by: 2).map { packed[$0] },
                              factory: stride(from: 1, to: 14, by: 2).map { packed[$0] })
    }

    /// `layer` 01 writes the HyperShift layer, as 02/0C's third argument does over USB. The
    /// first byte is the slot it goes to, as 02/0C's first argument is (#55, 2026-10-22).
    static func buttonFunctionPayload(id: UInt8, block: [UInt8], layer: UInt8 = 0, slot: UInt8 = 0x01) -> [UInt8] {
        [slot, id, layer] + block
    }

    /// What the DPI button's entry can hold, on every mouse with
    /// `RazerDevices.supportsDpiButtonBinding`. Actions the mouse can't run itself (media
    /// keys, Double Click, a gesture, a key it can't send) use `softwareBridge`: the mouse
    /// types F20 and MacRazer turns that into the saved action. A mouse with
    /// `RazerDevices.dpiButtonPrivateKeys` keeps `dpiCycle` under them instead, and MacRazer
    /// acts on its private keys in driver mode. No undocumented consumer-control payload is
    /// sent to the mouse.
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
                return "Shortcut \(shortcutLabel(hidUsage: usage, modifiers: modifiers))"
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
            return [0x02, 0x02, modifiers, usage, 0, 0, 0]
        }
    }

    /// What a reply's payload means, so `response(to:payload:)` knows how to fold it back.
    enum Reply: Equatable {
        case ack
        case battery
        case serial
        case dpiStages
        case dpi
        case brightness
    }

    /// A request ready for the wire: the key, an optional payload, and how to read the reply.
    struct Request: Equatable {
        let key: Key
        let payload: [UInt8]
        let reply: Reply
    }

    // MARK: - Framing

    /// Largest GATT write the mouse takes in one frame (the default ATT MTU of 23, less 3).
    static let frameSize = 20

    /// Header frame `[id, payloadLength, 0, 0] + key`, then the payload in 20-byte frames.
    static func frames(id: UInt8, request: Request) -> [Data] {
        var frames = [Data([id, UInt8(request.payload.count), 0, 0] + request.key.bytes)]
        var offset = 0
        while offset < request.payload.count {
            let end = min(offset + frameSize, request.payload.count)
            frames.append(Data(request.payload[offset..<end]))
            offset = end
        }
        return frames
    }

    static func dpiButtonPayload(for binding: DPIButtonBinding) -> Data {
        if let keyboard = binding.keyboardPayload {
            return Data([0x01, 0x60, 0x00] + keyboard)
        }
        if let buttonID = binding.buttonID {
            return Data([0x01, 0x60, 0x00, 0x01, 0x01, buttonID, 0, 0, 0, 0])
        }
        return Data([0x01, 0x60, 0x00] + dpiCycleBlock)
    }

    /// The DPI button's factory function, DPI Cycle. What "DPI Cycle (default)" writes back,
    /// and what a read of the entry must name as its factory block when it carries one.
    static let dpiCycleBlock: [UInt8] = [0x06, 0x01, 0x06, 0, 0, 0, 0]

    /// Why a read of the DPI button's entry, or of the profile in use, can't be used. The write
    /// path reads both first and stops on these, so they always mean nothing was written.
    enum DPIButtonEntryError: Error, Equatable {
        /// The reply isn't laid out as a read of entry 0x60, or what the button does now isn't
        /// a `DPIButtonBinding` (a macro, a profile switch, nothing at all).
        case unrecognized
        /// The mouse names a factory function other than DPI Cycle for the entry, so on this
        /// mouse it isn't the DPI button.
        case notTheDpiButton
        /// The mouse says it's using onboard profile `slot`, not profile 1. The write goes to
        /// profile 1's entry (`Key.dpiButtonSet`) while the reads around it see the profile in
        /// use, so it would change an entry nothing read, and never read back.
        case otherProfileInUse(UInt8)
    }

    /// Why a write of the DPI button's entry failed after the read before it went through.
    enum DPIButtonWriteError: Error, Equatable {
        /// The mouse refused the write or didn't answer it, so it may or may not have taken it.
        case notTaken
        /// The read after the write failed, or showed something other than what was written.
        case notReadBack
    }

    static let sleepTimeoutRange = 60...900
    static let sleepTimeoutStep = 15

    static func sleepTimeoutPayload(seconds: Int) -> Data? {
        guard sleepTimeoutRange.contains(seconds), seconds.isMultiple(of: sleepTimeoutStep) else { return nil }
        return Data([UInt8(seconds & 0xFF), UInt8((seconds >> 8) & 0xFF)])
    }

    static func parseSleepTimeout(_ payload: Data) throws -> Int {
        guard payload.count >= 2 else { throw HIDDevice.HIDError.badResponse }
        let value = Int(payload[0]) | (Int(payload[1]) << 8)
        guard sleepTimeoutRange.contains(value), value.isMultiple(of: sleepTimeoutStep) else {
            throw HIDDevice.HIDError.badResponse
        }
        return value
    }

    /// What the DPI button does now, from a read of entry 0x60. Fails closed, so that a write
    /// only ever replaces something this app understands (`DPIButtonEntryError`).
    ///
    /// Two layouts answer. The short one (`01 60 00` and the current block) has no factory
    /// block. The function-table one (`ButtonFunction`: `60, flag`, then the current and
    /// factory blocks interleaved) is how the Cobra HyperSpeed answers entries 0x04 and 0x05;
    /// with flag 0 its factory block must be DPI Cycle, the one sign a read gives that the
    /// entry really is this mouse's DPI button. With flag 01 the second block is a HyperShift
    /// layer instead, which says nothing about that, so only the current block is checked, as
    /// in the short layout.
    static func parseDpiButtonBinding(_ payload: Data) throws -> DPIButtonBinding {
        let bytes = Array(payload)
        let functionBlock: [UInt8]
        if bytes.count >= 10, bytes[0] == 0x01, bytes[1] == 0x60 {
            functionBlock = Array(bytes[3..<10])
        } else if bytes.count >= 16, bytes[0] == 0x60,
                  let entry = try? parseButtonFunction(id: 0x60, payload) {
            if bytes[1] == 0x00, entry.factory != dpiCycleBlock { throw DPIButtonEntryError.notTheDpiButton }
            functionBlock = entry.current
        } else {
            throw DPIButtonEntryError.unrecognized
        }

        if functionBlock == dpiCycleBlock { return .dpiCycle }
        if functionBlock[0] == 0x02, functionBlock[1] == 0x02,
           functionBlock[4...6].allSatisfy({ $0 == 0 }), functionBlock[3] != 0 {
            return .keyboardShortcut(hidUsage: functionBlock[3], modifiers: functionBlock[2])
        }
        // A mouse button is `01 01 id` and nothing after it, as `dpiButtonPayload` writes it.
        guard functionBlock[0] == 0x01, functionBlock[1] == 0x01,
              functionBlock[3...6].allSatisfy({ $0 == 0 }),
              let binding = DPIButtonBinding.allCases.first(where: { $0.buttonID == functionBlock[2] }) else {
            throw DPIButtonEntryError.unrecognized
        }
        return binding
    }

    /// Translate a macOS virtual key code into the USB HID usage the mouse's function table
    /// takes. Unknown keys fail closed instead of writing an ambiguous binding.
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
        case 0x45: key = "F12"; case 0x6F: key = "F20"
        case 0x4C: key = "⌦"; case 0x4F: key = "→"; case 0x50: key = "←"
        case 0x51: key = "↓"; case 0x52: key = "↑"
        default: key = "Key 0x\(String(hidUsage, radix: 16, uppercase: true))"
        }
        return label + key
    }

    /// Collects the notifications that answer one request: a header frame
    /// `[id, length, 0, 0, 0, 0, 0, status]` whose id matches, then continuation frames
    /// until `length` payload bytes have arrived.
    ///
    /// Frames before the matching header are ignored. The mouse sends an unsolicited
    /// `01 … 03` frame when notifications are first enabled, and a reply to an earlier
    /// request that timed out can still be in flight; neither carries this request's id.
    struct Assembler {
        let id: UInt8
        private(set) var status: UInt8?
        private var expected = 0
        private(set) var payload = Data()

        init(id: UInt8) { self.id = id }

        /// The reply is complete: header seen and every payload byte collected.
        var isComplete: Bool { status != nil && payload.count >= expected }

        /// Returns whether the frame was taken as this reply's header or payload, so the
        /// gesture trace can report the ones that weren't.
        @discardableResult
        mutating func add(_ frame: Data) -> Bool {
            let bytes = Array(frame)
            if status == nil {
                guard bytes.count >= 8, bytes[0] == id else { return false }
                status = bytes[7]
                expected = Int(bytes[1])
                return true
            }
            guard !isComplete else { return false }
            payload.append(contentsOf: bytes.prefix(expected - payload.count))
            return true
        }

        /// The finished payload, or the error the status byte stands for.
        func result() throws -> Data {
            guard let status, isComplete else { throw HIDDevice.HIDError.timeout }
            switch Status(rawValue: status) {
            case .ok: return payload
            case .notSupported: throw HIDDevice.HIDError.notSupported
            case .failure, nil: throw HIDDevice.HIDError.commandFailed
            }
        }
    }

    // MARK: - USB report → BLE request

    /// The BLE request for a USB-style report, or nil when there is no known BLE
    /// equivalent. `stages` is the mouse's current stage table, which a DPI change needs
    /// because BLE only switches DPI by rewriting that table.
    static func request(for report: RazerReport, stages: DPIStageTable?) -> Request? {
        let args = report.arguments
        switch (report.commandClass, report.commandId) {
        case (0x07, 0x80):
            return Request(key: .battery, payload: [], reply: .battery)
        case (0x00, 0x82):
            return Request(key: .serial, payload: [], reply: .serial)
        case (0x04, 0x86):
            return Request(key: .dpiStagesGet, payload: [], reply: .dpiStages)
        case (0x04, 0x85):
            return Request(key: .dpiStagesGet, payload: [], reply: .dpi)
        case (0x04, 0x06):
            // USB numbers stages from 0; the table carries them from 1.
            let count = min(Int(args[2]), RazerCommands.maxDPIStages)
            guard count > 0 else { return nil }
            let values = (0..<count).map { i in (Int(args[4 + i * 7]) << 8) | Int(args[5 + i * 7]) }
            let table = DPIStageTable(active: min(Int(args[1]), count - 1), values: values)
            return Request(key: .dpiStagesSet, payload: table.encoded(), reply: .ack)
        case (0x04, 0x05):
            // No direct "set DPI" over BLE. Selecting one of the existing stages is the
            // equivalent the DPI button does; an arbitrary value would mean rewriting the
            // stage table, which the app never does behind the user's back.
            let dpi = (Int(args[1]) << 8) | Int(args[2])
            guard let stages, let index = stages.values.firstIndex(of: dpi) else { return nil }
            let table = DPIStageTable(active: index, values: stages.values)
            return Request(key: .dpiStagesSet, payload: table.encoded(), reply: .ack)
        case (0x0F, 0x84):
            return Request(key: .brightnessGet(led: args[1]), payload: [], reply: .brightness)
        case (0x0F, 0x04):
            return Request(key: .brightnessSet(led: args[1]), payload: [args[2]], reply: .ack)
        case (0x0F, 0x02) where args[2] == 0x01:
            // Static colour only. Layout from #32: [0x04, 0, 0, 0, 0, r, g, b].
            return Request(key: .staticColor, payload: [0x04, 0, 0, 0, 0, args[6], args[7], args[8]],
                           reply: .ack)
        default:
            return nil
        }
    }

    // MARK: - BLE reply → USB report

    /// Fold a BLE reply back into the USB reply layout, so `RazerCommands`' parsers read it
    /// unchanged. The status is set to success; failures were already thrown by `Assembler`.
    static func response(to report: RazerReport, reply: Reply, payload: Data) throws -> RazerReport {
        var out = report
        out.status = RazerStatus.successful.rawValue
        let bytes = Array(payload)
        switch reply {
        case .ack:
            break
        case .battery:
            // 0-255, the same scale as USB. Verified on the Cobra HyperSpeed: 0x61 (97)
            // while the standard Battery Service reported 39%.
            guard let raw = bytes.first else { throw HIDDevice.HIDError.badResponse }
            out.arguments[1] = raw
        case .serial:
            for (i, b) in bytes.prefix(22).enumerated() { out.arguments[i] = b }
        case .dpiStages:
            let table = try DPIStageTable(decoding: bytes)
            out.arguments[1] = UInt8(table.active)
            out.arguments[2] = UInt8(table.values.count)
            for (i, value) in table.values.enumerated() {
                let base = 3 + i * 7
                out.arguments[base] = UInt8(i)
                out.arguments[base + 1] = UInt8(value >> 8)
                out.arguments[base + 2] = UInt8(value & 0xFF)
                out.arguments[base + 3] = UInt8(value >> 8)
                out.arguments[base + 4] = UInt8(value & 0xFF)
            }
        case .dpi:
            let table = try DPIStageTable(decoding: bytes)
            let value = table.values[table.active]
            out.arguments[1] = UInt8(value >> 8)
            out.arguments[2] = UInt8(value & 0xFF)
            out.arguments[3] = UInt8(value >> 8)
            out.arguments[4] = UInt8(value & 0xFF)
        case .brightness:
            guard let raw = bytes.first else { throw HIDDevice.HIDError.badResponse }
            out.arguments[2] = raw
        }
        return out
    }

    // MARK: - DPI stage table

    /// The BLE stage table: `[activeID, count]`, then per stage
    /// `[id, x_lo, x_hi, y_lo, y_hi, 0, 0]` with ids from 1 and little-endian DPI. The mouse
    /// leaves the final reserved byte off its replies (36 bytes for five stages, not 37),
    /// so decoding needs only the first five bytes of the last record.
    struct DPIStageTable: Equatable, Sendable {
        /// 0-based index into `values`.
        var active: Int
        var values: [Int]

        init(active: Int, values: [Int]) {
            self.active = active
            self.values = values
        }

        init(decoding bytes: [UInt8]) throws {
            guard bytes.count >= 2 else { throw HIDDevice.HIDError.badResponse }
            let count = Int(bytes[1])
            guard (1...RazerCommands.maxDPIStages).contains(count) else { throw HIDDevice.HIDError.badResponse }
            var ids: [UInt8] = []
            var values: [Int] = []
            for i in 0..<count {
                let base = 2 + i * 7
                guard bytes.count >= base + 5 else { throw HIDDevice.HIDError.badResponse }
                ids.append(bytes[base])
                values.append(Int(bytes[base + 1]) | (Int(bytes[base + 2]) << 8))
            }
            guard let active = ids.firstIndex(of: bytes[0]) else { throw HIDDevice.HIDError.badResponse }
            self.init(active: active, values: values)
        }

        /// The table with the stage after the active one selected, back to the first after
        /// the last, as the DPI button steps through them. The stages themselves don't change.
        /// Nil when there is only one stage, and nothing to step to.
        func nextStage() -> DPIStageTable? {
            guard values.count > 1 else { return nil }
            return DPIStageTable(active: (active + 1) % values.count, values: values)
        }

        func encoded() -> [UInt8] {
            var bytes: [UInt8] = [UInt8(active + 1), UInt8(values.count)]
            for (i, value) in values.enumerated() {
                let v = UInt16(max(100, min(value, 45000)))
                bytes += [UInt8(i + 1), UInt8(v & 0xFF), UInt8(v >> 8), UInt8(v & 0xFF), UInt8(v >> 8), 0, 0]
            }
            return bytes
        }
    }
}

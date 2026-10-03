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
        static func brightnessGet(led: UInt8) -> Key { Key(0x10, 0x85, 0x01, led) }
        static func brightnessSet(led: UInt8) -> Key { Key(0x10, 0x05, 0x01, led) }
        static let staticColor = Key(0x10, 0x04, 0x00, 0x00)
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

        mutating func add(_ frame: Data) {
            let bytes = Array(frame)
            if status == nil {
                guard bytes.count >= 8, bytes[0] == id else { return }
                status = bytes[7]
                expected = Int(bytes[1])
                return
            }
            guard !isComplete else { return }
            payload.append(contentsOf: bytes.prefix(expected - payload.count))
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
    struct DPIStageTable: Equatable {
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

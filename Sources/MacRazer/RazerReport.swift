// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Port of OpenRazer's `struct razer_report` (90 bytes on the wire).
/// Source: reference/openrazer/driver/razercommon.h  (struct razer_report, 90B)
///
/// Wire layout (big-endian remaining_packets):
///   [0]      status
///   [1]      transaction_id
///   [2..3]   remaining_packets (be16)
///   [4]      protocol_type (0x00)
///   [5]      data_size
///   [6]      command_class
///   [7]      command_id
///   [8..87]  arguments[80]
///   [88]     crc (xor of bytes [2..87])
///   [89]     reserved (0x00)
struct RazerReport {
    var status: UInt8 = 0x00
    var transactionId: UInt8 = 0x00
    var remainingPackets: UInt16 = 0x0000
    var protocolType: UInt8 = 0x00
    var dataSize: UInt8 = 0x00
    var commandClass: UInt8 = 0x00
    var commandId: UInt8 = 0x00
    var arguments: [UInt8] = Array(repeating: 0x00, count: 80)
    // crc + reserved are derived on serialize.

    static let wireSize = 90

    /// Mirror of `get_razer_report(command_class, command_id, data_size)`.
    init(commandClass: UInt8, commandId: UInt8, dataSize: UInt8) {
        self.commandClass = commandClass
        self.commandId = commandId
        self.dataSize = dataSize
    }

    /// Serialize to the 90-byte wire buffer, computing the CRC.
    func serialized() -> [UInt8] {
        var b = [UInt8](repeating: 0x00, count: RazerReport.wireSize)
        b[0] = status
        b[1] = transactionId
        b[2] = UInt8((remainingPackets >> 8) & 0xFF) // big endian
        b[3] = UInt8(remainingPackets & 0xFF)
        b[4] = protocolType
        b[5] = dataSize
        b[6] = commandClass
        b[7] = commandId
        for i in 0..<80 {
            b[8 + i] = i < arguments.count ? arguments[i] : 0x00
        }
        b[88] = RazerReport.crc(of: b) // xor of bytes [2..87]
        b[89] = 0x00                   // reserved
        return b
    }

    /// Parse a 90-byte response buffer back into a report.
    static func parse(_ b: [UInt8]) -> RazerReport? {
        guard b.count >= wireSize else { return nil }
        var r = RazerReport(commandClass: b[6], commandId: b[7], dataSize: b[5])
        r.status = b[0]
        r.transactionId = b[1]
        r.remainingPackets = (UInt16(b[2]) << 8) | UInt16(b[3])
        r.protocolType = b[4]
        r.arguments = Array(b[8..<88])
        return r
    }

    /// Mirror of `razer_calculate_crc`: xor of bytes index 2..87 inclusive.
    static func crc(of buffer: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for i in 2..<88 where i < buffer.count {
            crc ^= buffer[i]
        }
        return crc
    }
}

/// Response status codes — razercommon.h "Report Responses".
enum RazerStatus: UInt8 {
    case new = 0x00
    case busy = 0x01
    case successful = 0x02
    case failure = 0x03
    case timeout = 0x04
    case notSupported = 0x05
}

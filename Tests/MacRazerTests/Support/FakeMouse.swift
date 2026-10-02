// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

@testable import MacRazer

/// A mouse that remembers the last value written to each setting and answers reads with
/// it, since the protocol's set and get layouts mirror each other. `refuse` makes chosen
/// commands answer FAILURE, and `clamp` lets a write land as something else.
final class FakeMouse: TransactionChannel {
    enum Call: Equatable {
        case once(UInt8, UInt8)
        case retried(UInt8, UInt8, attempts: Int)
    }

    private(set) var calls: [Call] = []
    var refuse: (RazerReport) -> Bool = { _ in false }
    var clamp: (RazerReport) -> RazerReport = { $0 }
    /// Last written arguments, keyed by command class, the read's command id and, for
    /// lighting (class 0x0F), the LED group, so each group holds its own brightness.
    private var stored: [UInt32: [UInt8]] = [:]

    /// What a mouse does with a transaction id it doesn't answer to. Both are real: a Cobra
    /// HyperSpeed times out on some wrong ids and garbles others.
    enum WrongId { case timeout, staleStatus }

    /// Which ids this mouse answers to, by command class. Missing class = answers to any id.
    var acceptedIds: [UInt8: Set<UInt8>] = [:]
    var wrongId = WrongId.timeout
    /// The transaction id each call carried, nil for "the registry's".
    private(set) var transactionIds: [UInt8?] = []

    func send(_ report: RazerReport) throws -> RazerReport {
        try send(report, transactionId: nil)
    }

    func sendWithRetry(_ report: RazerReport, attempts: Int) throws -> RazerReport {
        try sendWithRetry(report, attempts: attempts, transactionId: nil)
    }

    func send(_ report: RazerReport, transactionId: UInt8?) throws -> RazerReport {
        calls.append(.once(report.commandClass, report.commandId))
        transactionIds.append(transactionId)
        return try answer(report, transactionId: transactionId)
    }

    func sendWithRetry(_ report: RazerReport, attempts: Int, transactionId: UInt8?) throws -> RazerReport {
        calls.append(.retried(report.commandClass, report.commandId, attempts: attempts))
        transactionIds.append(transactionId)
        return try answer(report, transactionId: transactionId)
    }

    /// The mouse already holds this setting, as if `write` had been sent earlier.
    func holds(_ write: RazerReport) {
        stored[key(write, id: write.commandId | 0x80)] = write.arguments
    }

    /// For values nothing writes, like the battery level: answer `read` with these bytes.
    func answers(_ read: RazerReport, _ edit: (inout [UInt8]) -> Void) {
        var arguments = read.arguments
        edit(&arguments)
        stored[key(read, id: read.commandId)] = arguments
    }

    private func key(_ report: RazerReport, id: UInt8) -> UInt32 {
        let led = report.commandClass == 0x0F ? UInt32(report.arguments[1]) : 0
        return UInt32(report.commandClass) << 16 | UInt32(id) << 8 | led
    }

    private func answer(_ report: RazerReport, transactionId: UInt8?) throws -> RazerReport {
        if let id = transactionId, let accepted = acceptedIds[report.commandClass], !accepted.contains(id) {
            switch wrongId {
            case .timeout: throw HIDDevice.HIDError.timeout
            case .staleStatus:
                var stale = report
                stale.status = 0x00
                return stale
            }
        }
        if refuse(report) { throw HIDDevice.HIDError.commandFailed }
        var reply = report
        reply.status = RazerStatus.successful.rawValue
        if report.commandId & 0x80 == 0 {
            // A write: remember it under the matching read's id (set 0x05 → get 0x85).
            let landed = clamp(report)
            stored[key(report, id: report.commandId | 0x80)] = landed.arguments
        } else if let previous = stored[key(report, id: report.commandId)] {
            reply.arguments = previous
        }
        return reply
    }
}

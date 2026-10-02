// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// A channel whose transaction id can be chosen per command. `HIDDevice` is one. Everyday
/// traffic never needs this: the registry knows each supported model's id. The device test
/// does, because an unknown model may answer to none of the ids the app would guess.
protocol TransactionChannel: DeviceProbeChannel {
    func send(_ report: RazerReport, transactionId: UInt8?) throws -> RazerReport
    func sendWithRetry(_ report: RazerReport, attempts: Int, transactionId: UInt8?) throws -> RazerReport
}

extension HIDDevice: TransactionChannel {}

/// Stamps chosen transaction ids instead of the registry's: `matrix` for lighting commands
/// (class 0x0F) and `standard` for the rest, the same split `RazerDeviceInfo` makes.
struct FixedTransactionChannel: DeviceProbeChannel {
    let base: TransactionChannel
    let standard: UInt8
    let matrix: UInt8

    func transactionId(for report: RazerReport) -> UInt8 {
        report.commandClass == 0x0F ? matrix : standard
    }

    func send(_ report: RazerReport) throws -> RazerReport {
        try base.send(report, transactionId: transactionId(for: report))
    }

    func sendWithRetry(_ report: RazerReport, attempts: Int) throws -> RazerReport {
        try base.sendWithRetry(report, attempts: attempts, transactionId: transactionId(for: report))
    }
}

/// Records every command that passes through, as evidence for the device test's report: what
/// was asked, with which transaction id, what came back or what went wrong, and how long it
/// took. This is the raw output CONTRIBUTING asks contributors to paste, gathered for them.
final class RecordingChannel: TransactionChannel {
    struct Exchange: Codable, Equatable {
        let commandClass: UInt8
        let commandId: UInt8
        /// nil when the registry's id was used.
        let transactionId: UInt8?
        let status: UInt8?
        /// The first bytes of the answer's arguments. Enough to see read-backs and echoes;
        /// the rest of a 90-byte report is padding for every command the test sends.
        let response: [UInt8]
        let error: String?
        let milliseconds: Int
    }

    /// How many argument bytes each exchange keeps.
    static let responseBytes = 8
    /// A ceiling on the evidence one session keeps, so a misbehaving device can't grow the
    /// report without bound. A full test sends well under this.
    static let maxExchanges = 150

    private let base: TransactionChannel
    private(set) var exchanges: [Exchange] = []

    init(base: TransactionChannel) { self.base = base }

    func send(_ report: RazerReport) throws -> RazerReport {
        try record(report, transactionId: nil) { try base.send(report) }
    }

    func sendWithRetry(_ report: RazerReport, attempts: Int) throws -> RazerReport {
        try record(report, transactionId: nil) { try base.sendWithRetry(report, attempts: attempts) }
    }

    func send(_ report: RazerReport, transactionId: UInt8?) throws -> RazerReport {
        try record(report, transactionId: transactionId) { try base.send(report, transactionId: transactionId) }
    }

    func sendWithRetry(_ report: RazerReport, attempts: Int, transactionId: UInt8?) throws -> RazerReport {
        try record(report, transactionId: transactionId) {
            try base.sendWithRetry(report, attempts: attempts, transactionId: transactionId)
        }
    }

    private func record(_ report: RazerReport, transactionId: UInt8?,
                        _ body: () throws -> RazerReport) throws -> RazerReport {
        let start = Date()
        func keep(_ status: UInt8?, _ response: [UInt8], _ error: Error?) {
            guard exchanges.count < Self.maxExchanges else { return }
            exchanges.append(Exchange(
                commandClass: report.commandClass, commandId: report.commandId,
                transactionId: transactionId, status: status, response: response,
                error: error.map { String(describing: $0) },
                milliseconds: Int(Date().timeIntervalSince(start) * 1000)))
        }
        do {
            let answer = try body()
            keep(answer.status, Array(answer.arguments.prefix(Self.responseBytes)), nil)
            return answer
        } catch {
            keep(nil, [], error)
            throw error
        }
    }
}

extension DeviceProbe {
    /// Every transaction id OpenRazer's mouse driver uses, most common first. An unknown model
    /// almost certainly answers to one of these.
    static let knownTransactionIds: [UInt8] = [0x1F, 0x3F, 0xFF, 0x08, 0x80]

    /// One id tried for everything but lighting, and what it got back.
    struct TransactionAttempt {
        let id: UInt8
        let result: Result<RazerReport, Error>
        /// Status 0x02. `send` passes unknown statuses through rather than throwing, and a
        /// mouse ignoring a wrong id can leave a stale or zero status behind, which must not
        /// count as an answer.
        var answered: Bool { (try? result.get())?.status == RazerStatus.successful.rawValue }
    }

    /// One id tried for lighting: a whole brightness sweep, since a refusal on one LED group
    /// says nothing about the id when most models answer on only some groups.
    struct MatrixAttempt {
        let id: UInt8
        let sweep: [LEDAnswer]
        var answeredGroups: [String] {
            sweep.filter { (try? $0.result.get())?.response.status == RazerStatus.successful.rawValue }.map(\.name)
        }
        var answered: Bool { !answeredGroups.isEmpty }
    }

    /// The candidates to try, `preferred` (the registry's id, when the model is known) first
    /// and no id twice.
    static func transactionCandidates(preferred: UInt8?) -> [UInt8] {
        var seen = Set<UInt8>()
        return ([preferred].compactMap { $0 } + knownTransactionIds).filter { seen.insert($0).inserted }
    }

    /// Tries a harmless read with every candidate id, for everything but lighting.
    ///
    /// Every candidate, not just until one answers. Measured on a Cobra HyperSpeed: it
    /// answers to 0x1F, 0x3F and 0x08 alike, times out on 0xFF and garbles 0x80, so the
    /// receiver checks only some of the id's bits. Which ids answer is the evidence a
    /// maintainer needs to choose a new model's entry; "the first one worked" is not. About
    /// two seconds on that mouse, once per test.
    static func discoverTransactionIds(_ channel: TransactionChannel, read: RazerReport,
                                       preferred: UInt8?) -> [TransactionAttempt] {
        transactionCandidates(preferred: preferred).map { id in
            TransactionAttempt(id: id, result: Result {
                try channel.sendWithRetry(read, attempts: DeviceProbe.attempts, transactionId: id)
            })
        }
    }

    /// As `discoverTransactionIds`, for lighting (class 0x0F), whose id can differ.
    static func discoverMatrixTransactionIds(_ channel: TransactionChannel, standard: UInt8,
                                             preferred: UInt8?) -> [MatrixAttempt] {
        transactionCandidates(preferred: preferred).map { id in
            MatrixAttempt(id: id, sweep: brightnessSweep(
                FixedTransactionChannel(base: channel, standard: standard, matrix: id)))
        }
    }

    /// The id to use from here on: the registry's if the mouse answered to it, else the first
    /// candidate that answered. Candidates put the registry's first, so that is one rule.
    static func chosenId(_ attempts: [TransactionAttempt]) -> UInt8? { attempts.first(where: \.answered)?.id }
    static func chosenId(_ attempts: [MatrixAttempt]) -> UInt8? { attempts.first(where: \.answered)?.id }
}

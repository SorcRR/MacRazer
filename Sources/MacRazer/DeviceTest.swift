// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// What the device test found, in the shape a maintainer needs to add or confirm a model:
/// every field of `RazerDeviceInfo` can be filled from it (see the plan in the PR). It is
/// what Copy, the GitHub issue and, later, Send all carry, so the person sending it can read
/// exactly what leaves their Mac.
///
/// Never in here: the serial number (the app keys a mouse by it, and it names one physical
/// unit), USB locations, or anything about the Mac beyond its OS version.
struct DeviceReport: Codable, Equatable {
    static let currentSchema = 3

    var schemaVersion = DeviceReport.currentSchema
    var appVersion: String
    var macOSVersion: String
    var device: Device
    /// What MacRazer already knew about this model, if anything.
    var registry: Registry?
    var identify: StepRecord<IdentifyData>
    var battery: StepRecord<BatteryData>
    var dpi: StepRecord<DPIData>
    var polling: StepRecord<PollingData>
    var lighting: StepRecord<LightingData>
    var buttons: StepRecord<ButtonsData>
    /// What the mouse answers to commands the steps don't use, read once after Identify.
    /// Schema 2; nil in earlier reports and when Identify found no id to ask with.
    var capabilities: CapabilitiesData?
    var verdict: DeviceTestVerdict?
    var comment: String?
    /// How the person would like to be credited in the README, if at all.
    var credit: String?
    /// For a reply. Only ever sent to the maintainer; never put in a GitHub issue.
    var replyEmail: String?
    /// Steps whose per-command evidence was left out to keep the report under the size the
    /// Worker accepts (`DeviceReportOutput.fitted`). Their outcomes and data are all still here.
    var exchangesDropped: [String]?

    struct Device: Codable, Equatable {
        var vendorID: Int
        var productID: Int
        var name: String
        /// The person's answer: the cable and the dongle both enumerate as USB.
        var connection: Connection?
        var interfaces: [DeviceProbe.Interface]
        /// Index into `interfaces` of the one the app opened for control.
        var controlInterface: Int?
    }

    enum Connection: String, Codable { case cable, dongle }

    struct Registry: Codable, Equatable {
        var name: String
        var fullySupported: Bool
        var hasBattery: Bool
        var hasLighting: Bool
        var maxDPI: Int
        var transactionId: UInt8
        var matrixTransactionId: UInt8
        var brightnessLed: UInt8

        init(_ info: RazerDeviceInfo) {
            name = info.name
            fullySupported = info.fullySupported
            hasBattery = info.hasBattery
            hasLighting = info.hasLighting
            maxDPI = info.maxDPI
            transactionId = info.transactionId
            matrixTransactionId = info.matrixTransactionId
            brightnessLed = info.brightnessLed
        }
    }

    enum Outcome: String, Codable {
        /// Ran, and everything it checked held.
        case passed
        /// Ran, and something that should have worked didn't.
        case failed
        /// The mouse says it doesn't have this (refused, consistently). Not a failure for a
        /// model nobody knows yet: an unlit mouse refusing lighting is the answer.
        case notSupported
        /// The person skipped it, or it never ran.
        case skipped
    }

    struct StepRecord<Data: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        var outcome: Outcome = .skipped
        var data: Data?
        var error: String?
        var exchanges: [RecordingChannel.Exchange] = []
    }

    struct TransactionResult: Codable, Equatable {
        var id: UInt8
        var answered: Bool
        /// Heard, but said no (status 0x03 or 0x05).
        var refused: Bool = false
        /// The groups that answered, for lighting attempts.
        var groups: [String]?
        var error: String?
    }

    struct IdentifyData: Codable, Equatable {
        var firmware: String?
        /// Every id tried with a firmware read.
        var standardAttempts: [TransactionResult]
        /// Every id tried again with a DPI read, when none answered the firmware read: some
        /// models don't have that command, and refusing it says little about the id.
        var dpiAttempts: [TransactionResult]?
        var lightingAttempts: [TransactionResult]
        var standardId: UInt8?
        var lightingId: UInt8?
        /// When no id got an answer on the interface MacRazer picked: the firmware read tried
        /// on the mouse's other interfaces that can carry the control report. An answer here
        /// means the app picks the wrong interface for this mouse.
        var otherInterfaces: [InterfaceAttempt]?
    }

    struct InterfaceAttempt: Codable, Equatable {
        var usagePage: Int
        var usage: Int
        var attempts: [TransactionResult]
    }

    struct BatteryData: Codable, Equatable {
        var raw: UInt8?
        var percent: Int?
        var charging: Bool?
    }

    struct DPIData: Codable, Equatable {
        var original: Int?
        var test: Int?
        var readBack: Int?
        var restored: Bool = false
        var stages: [Int]?
        /// The stage table's own numbering, as the mouse answered: the first stage's number
        /// (0 or 1) and the active-stage byte. Mice differ, and a write numbered the other way
        /// selects the wrong stage.
        var firstStageNumber: Int?
        var activeStageByte: Int?
        /// Optional, run only when asked: what the mouse kept when asked for the protocol's
        /// ceiling. A mouse that clamps reads back its real maximum.
        var maxProbe: Int?
    }

    struct PollingData: Codable, Equatable {
        var original: Int?
        var test: Int?
        var readBack: Int?
        var restored: Bool = false
    }

    struct LightingData: Codable, Equatable {
        /// Raw 0-255 brightness per group that answered, before the test touched it.
        var groups: [String: UInt8] = [:]
        /// The lights were taken to zero for a moment. Brightness reads back, so this part
        /// is restored exactly.
        var dimShown = false
        /// The mouse was set to static red, then back to the app's own lighting setting.
        /// Skipped where that setting isn't known (the CLI), since an effect can't be read
        /// back and the mouse would be left on a guess.
        var redShown = false
        /// The person's answers: true, false, or nil for not sure.
        var dimmed: Bool?
        var turnedRed: Bool?
        var restored: Bool = false
    }

    struct ButtonsData: Codable, Equatable {
        /// Each distinct input seen, as "page:usage" in hex, e.g. "09:04" for button 4 or
        /// "07:1e" for a key that types 1.
        var seen: [String] = []
    }

    /// One answer per read in `DeviceTestSteps.capabilityReads`, in that order.
    struct CapabilitiesData: Codable, Equatable {
        var reads: [CapabilityRead] = []
        /// Every entry of the mouse's button function table that answered, read when one of
        /// the `buttonFunction` reads did (`DeviceTestSteps.readButtonTable`). Nil when the
        /// mouse has no table.
        var buttonTable: [ButtonEntry]?
    }

    /// One entry of a button function table: its id and the seven-byte block it holds (a
    /// function type, the data's length, then the data, e.g. 01 01 04 for mouse button 4).
    struct ButtonEntry: Codable, Equatable {
        var id: UInt8
        var block: [UInt8]
    }

    struct CapabilityRead: Codable, Equatable {
        /// Which read, e.g. "pollingRate2" or "zoneEffect" (with `led`).
        var name: String
        var commandClass: UInt8
        var commandId: UInt8
        /// The LED id, for the lighting reads that take one.
        var led: UInt8?
        var answer: CapabilityAnswer
        /// The first `DeviceTestSteps.capabilityResponseBytes` argument bytes of an answer.
        var response: [UInt8]?
    }

    enum CapabilityAnswer: String, Codable {
        /// The mouse has it: status 0x02.
        case answered
        /// Status 0x03. Often a wrong argument (an LED the mouse doesn't have) rather than
        /// a missing command.
        case failed
        /// Status 0x05: the mouse doesn't have the command.
        case notSupported
        /// A timeout or a reply that made no sense.
        case noAnswer
    }
}

extension DeviceReport {
    /// The verdict for the steps as they stand. Buttons are left out: there is nothing a mouse
    /// can get wrong by having a particular set of them.
    func currentVerdict() -> DeviceTestVerdict {
        DeviceTestVerdict.make(knownFullySupported: registry?.fullySupported ?? false, steps: [
            ("Identify", identify.outcome), ("Battery", battery.outcome), ("DPI", dpi.outcome),
            ("Polling rate", polling.outcome), ("Lighting", lighting.outcome),
        ])
    }
}

// MARK: - Verdict

/// What the test concludes, from the step outcomes and what the registry expected.
///
/// "Passed" is strict on purpose: a confirmation goes into the README's supported-mice table,
/// so it has to mean every check held, nothing was skipped, and on a known model the ids on
/// record were the ones that answered.
struct DeviceTestVerdict: Codable, Equatable {
    enum Kind: String, Codable {
        case confirmed
        case possibleRegression
        case newAllPassed
        case newPartlyPassed
        case partlyTested
    }

    let kind: Kind
    let passed: [String]
    let failed: [String]
    let notSupported: [String]
    let skipped: [String]

    /// The steps that decide the verdict. Buttons are information only: there is nothing a
    /// mouse can get wrong by having a particular set of them.
    static func make(knownFullySupported: Bool, steps: [(name: String, outcome: DeviceReport.Outcome)]) -> DeviceTestVerdict {
        func names(_ o: DeviceReport.Outcome) -> [String] { steps.filter { $0.outcome == o }.map(\.name) }
        let passed = names(.passed), failed = names(.failed)
        let notSupported = names(.notSupported), skipped = names(.skipped)
        let kind: Kind
        if !failed.isEmpty {
            kind = knownFullySupported ? .possibleRegression : .newPartlyPassed
        } else if !skipped.isEmpty {
            kind = .partlyTested
        } else {
            kind = knownFullySupported ? .confirmed : .newAllPassed
        }
        return DeviceTestVerdict(kind: kind, passed: passed, failed: failed,
                                 notSupported: notSupported, skipped: skipped)
    }

    /// What the window says once Send worked. A known model that passed everything is told
    /// it is already supported: the report is what lets the supported list say so.
    func thankYou(firmware: String?) -> String {
        func names(_ steps: [String]) -> String {
            steps.count < 2 ? steps.joined() : steps.dropLast().joined(separator: ", ") + " and " + steps.last!
        }
        switch kind {
        case .confirmed:
            return "Your mouse is already fully supported, and your report confirms it"
                + (firmware.map { " on firmware \($0)" } ?? "") + ". It helps keep the supported list accurate."
        case .possibleRegression:
            return "Your mouse should be fully supported, but \(names(failed)) didn't work. Your report shows us what to fix."
        case .newAllPassed:
            return "Everything worked. Once we've looked at your report, your mouse moves to the supported list."
        case .newPartlyPassed:
            return "\(names(failed)) didn't work, so your report shows us exactly what to fix for your mouse."
        case .partlyTested:
            return "Some steps were skipped, so this is a partial report. It still helps."
        }
    }

    /// The email subject's prefix, so the maintainer's inbox sorts itself.
    var subjectPrefix: String {
        let ran = passed.count + failed.count
        switch kind {
        case .confirmed: return "Confirmation"
        case .possibleRegression: return "Possible regression"
        case .newAllPassed: return "New mouse: all passed"
        case .newPartlyPassed: return "New mouse: \(passed.count) of \(ran) passed"
        case .partlyTested: return "Partly tested"
        }
    }
}

// MARK: - Steps

/// The test steps, as plain functions over a channel so they can be driven by a fake mouse.
/// Each runs in one go on the device queue: whatever it changes, it puts back before it
/// returns, on every path, so nothing else the app does can see a test value as the user's.
enum DeviceTestSteps {
    /// Runs a step over the ids Identify found, keeping the evidence of every command it sent.
    /// Identify is the exception: it chooses ids itself, and records its own exchanges.
    static func recorded<T>(_ device: TransactionChannel, standard: UInt8, matrix: UInt8,
                            overrides: [UInt16: UInt8] = [:],
                            _ step: (DeviceProbeChannel) -> DeviceReport.StepRecord<T>) -> DeviceReport.StepRecord<T> {
        let recording = RecordingChannel(base: device)
        var record = step(FixedTransactionChannel(base: recording, standard: standard, matrix: matrix,
                                                  overrides: overrides))
        record.exchanges = recording.exchanges
        return record
    }

    /// `identify` on a real mouse, which can also try its other interfaces
    /// (`tryInterfaces`) when no id answers on the one MacRazer picked.
    static func identifyMouse(_ device: HIDDevice, registry: RazerDeviceInfo?)
        -> (record: DeviceReport.StepRecord<DeviceReport.IdentifyData>, sweep: [DeviceProbe.LEDAnswer]?) {
        identify(device, registry: registry, others: {
            device.withOtherControlInterfaces { tryInterfaces($0, preferred: registry?.transactionId) }
        })
    }

    /// Tries every transaction id, then reads the firmware with the one chosen. `others` is
    /// asked only when no id got any reply, answer or refusal.
    static func identify(_ device: TransactionChannel, registry: RazerDeviceInfo?,
                         others: () -> [DeviceReport.InterfaceAttempt] = { [] })
        -> (record: DeviceReport.StepRecord<DeviceReport.IdentifyData>, sweep: [DeviceProbe.LEDAnswer]?) {
        let recording = RecordingChannel(base: device)
        let firmware = DeviceProbe.discoverTransactionIds(recording, read: RazerCommands.getFirmwareVersion(),
                                                          preferred: registry?.transactionId)
        let dpi = firmware.contains(where: \.answered) ? nil
            : DeviceProbe.discoverTransactionIds(recording, read: RazerCommands.getDPI(), preferred: registry?.transactionId)
        let standard = firmware + (dpi ?? [])
        // An answer to either read beats a refusal of either, and the firmware read's come first.
        let standardId = DeviceProbe.chosenId(standard)
        let lighting = DeviceProbe.discoverMatrixTransactionIds(recording, standard: standardId ?? 0x1F,
                                                                preferred: registry?.matrixTransactionId)
        let lightingId = DeviceProbe.chosenId(lighting)

        var data = DeviceReport.IdentifyData(
            standardAttempts: results(firmware), dpiAttempts: dpi.map(results),
            lightingAttempts: lighting.map {
                .init(id: $0.id, answered: $0.answered, refused: $0.refused, groups: $0.answeredGroups, error: nil)
            },
            standardId: standardId, lightingId: lightingId)
        // The chosen id's own firmware answer, so the version costs no extra read.
        if let answer = firmware.first(where: { $0.id == standardId && $0.answered }), case .success(let r) = answer.result {
            data.firmware = RazerCommands.parseFirmwareVersion(r)
        }
        if standardId == nil {
            let tried = others()
            if !tried.isEmpty { data.otherInterfaces = tried }
        }

        // Passed only when some read got a real answer. On a known model, the ids on record
        // must be ones the mouse answers to: that is the regression a confirmation exists to
        // catch, and lighting's id counts only where the model has lighting at all.
        var outcome: DeviceReport.Outcome = standard.contains(where: \.answered) ? .passed : .failed
        if let registry {
            if !standard.contains(where: { $0.id == registry.transactionId && $0.answered }) { outcome = .failed }
            if registry.hasLighting, !lighting.contains(where: { $0.id == registry.matrixTransactionId && $0.answered }) {
                outcome = .failed
            }
        }
        let sweep = lighting.first(where: { $0.id == lightingId })?.sweep
        return (.init(outcome: outcome, data: data, exchanges: recording.exchanges), sweep)
    }

    /// The firmware read with every id, on each of `interfaces`: other interfaces of the
    /// mouse, for when the one MacRazer picked didn't answer.
    static func tryInterfaces(_ interfaces: [(usagePage: Int, usage: Int, channel: TransactionChannel)],
                              preferred: UInt8?) -> [DeviceReport.InterfaceAttempt] {
        interfaces.map { usagePage, usage, channel in
            .init(usagePage: usagePage, usage: usage,
                  attempts: results(DeviceProbe.discoverTransactionIds(channel, read: RazerCommands.getFirmwareVersion(),
                                                                       preferred: preferred)))
        }
    }

    private static func results(_ attempts: [DeviceProbe.TransactionAttempt]) -> [DeviceReport.TransactionResult] {
        attempts.map {
            .init(id: $0.id, answered: $0.answered, refused: $0.refused, groups: nil,
                  error: { if case .failure(let e) = $0.result { return String(describing: e) }; return nil }($0))
        }
    }

    /// The ids the other steps use: what Identify found, else the registry's, else 0x1F.
    static func chosenIds(_ identify: DeviceReport.StepRecord<DeviceReport.IdentifyData>, registry: RazerDeviceInfo?)
        -> (standard: UInt8, matrix: UInt8) {
        let standard = identify.data?.standardId ?? registry?.transactionId ?? 0x1F
        return (standard, identify.data?.lightingId ?? standard)
    }

    /// Read-only commands asked once, to see what else the mouse can do. Each is a get (id
    /// 0x80 or above): nothing here changes a setting. Sources: OpenRazer for polling_rate2,
    /// idle time, the low-battery threshold, Smart-Reel and scroll acceleration; the
    /// Basilisk V4 Pro's own replies (#55) for the wheel mode and levels, the onboard profile
    /// slots, the button function table and the per-zone effect read, which finds lighting
    /// zones the brightness sweep doesn't try (the V4 Pro's underglow is 0x0A).
    static let capabilityReads: [(name: String, report: RazerReport)] = {
        func read(_ commandClass: UInt8, _ id: UInt8, _ size: UInt8, _ args: [UInt8] = []) -> RazerReport {
            var r = RazerReport(commandClass: commandClass, commandId: id, dataSize: size)
            for (i, byte) in args.enumerated() { r.arguments[i] = byte }
            return r
        }
        var reads: [(String, RazerReport)] = [
            ("pollingRate2", read(0x00, 0xC0, 0x01)),
            ("idleTime", read(0x07, 0x83, 0x02)),
            ("lowBatteryThreshold", read(0x07, 0x82, 0x01)),
            ("smartReel", read(0x02, 0x97, 0x02, [Razer.varstore])),
            ("scrollAcceleration", read(0x02, 0x96, 0x02, [Razer.varstore])),
            ("scrollAccelerationLevel", read(0x02, 0xA2, 0x02, [Razer.varstore])),
            ("smartReelSensitivity", read(0x02, 0xA3, 0x02, [Razer.varstore])),
            ("wheelMode", read(0x02, 0xB0, 0x02, [Razer.varstore])),
            ("profileSlots", read(0x05, 0x81, 0x0A)),
            ("activeProfileSlot", read(0x05, 0x84, 0x0A)),
            ("buttonFunction", buttonFunctionRead(0x04)),
            ("buttonFunction", buttonFunctionRead(0x05)),
        ]
        // Every LED id OpenRazer names, and a few past them.
        for led in UInt8(0x00)...0x11 {
            reads.append(("zoneEffect", read(0x0F, 0x82, 0x0C, [Razer.varstore, led])))
        }
        return reads
    }()

    /// How many argument bytes each answer keeps: enough for a zone's whole effect body
    /// (args 2-11, its colours included), more than the steps' 8.
    static let capabilityResponseBytes = 12

    /// `readCapabilities` with the ids Identify chose, or nil when no id answered: every read
    /// would only time out. Shared by the app and the CLI so their reports can't differ.
    static func capabilities(_ device: TransactionChannel,
                             identify: DeviceReport.StepRecord<DeviceReport.IdentifyData>,
                             registry: RazerDeviceInfo?) -> DeviceReport.CapabilitiesData? {
        guard identify.data?.standardId != nil else { return nil }
        let ids = chosenIds(identify, registry: registry)
        let channel = FixedTransactionChannel(base: device, standard: ids.standard, matrix: ids.matrix,
                                              overrides: registry?.transactionOverrides ?? [:])
        var data = readCapabilities(channel)
        if data.reads.contains(where: { $0.name == "buttonFunction" && $0.answer == .answered }) {
            data.buttonTable = readButtonTable(channel)
        }
        return data
    }

    /// A button function table entry on the base layer: args [VARSTORE, id, layer 0], and
    /// the answer's args 3-9 hold the entry's block. Read from the Basilisk V4 Pro (#55).
    static func buttonFunctionRead(_ id: UInt8) -> RazerReport {
        var r = RazerReport(commandClass: 0x02, commandId: 0x8C, dataSize: 0x0A)
        r.arguments[0] = Razer.varstore
        r.arguments[1] = id
        return r
    }

    /// The entry ids `readButtonTable` asks for. The Basilisk V4 Pro's table (#55) runs from
    /// 0x02 to 0x80 with gaps, so this goes some way past it for mice with more buttons.
    static let buttonTableIds = UInt8(0x01)...0x9F

    /// Reads each of `buttonTableIds` on the base layer and keeps the entries that answer:
    /// with the buttons the person pressed, enough to work out a new mouse's table. A read
    /// only, like the rest. Stops after a few timeouts in a row, as a mouse that stopped
    /// answering would otherwise cost a third of a second per id.
    static func readButtonTable(_ channel: DeviceProbeChannel) -> [DeviceReport.ButtonEntry] {
        var entries: [DeviceReport.ButtonEntry] = []
        var timeouts = 0
        for id in buttonTableIds {
            do {
                let answer = try channel.sendWithRetry(buttonFunctionRead(id), attempts: 1)
                timeouts = 0
                // Every read here is the same command, so a reply left over from the last id
                // would pass `send`'s check. The id it echoes is what tells them apart. An
                // all-zero block isn't a function (even Disabled is 00 01 00): no entry.
                let block = Array(answer.arguments[3..<10])
                guard answer.arguments[1] == id, block.contains(where: { $0 != 0 }) else { continue }
                entries.append(.init(id: id, block: block))
            } catch HIDDevice.HIDError.commandFailed, HIDDevice.HIDError.notSupported {
                timeouts = 0
            } catch {
                timeouts += 1
                if timeouts == 4 { break }
            }
        }
        return entries
    }

    /// Asks each of `capabilityReads` once and keeps the answer. No retry: a refusal or a
    /// timeout says the same the second time, and `noAnswer` already marks a read that
    /// didn't come back. The answers are the evidence, so no exchanges are kept: they would
    /// only repeat them.
    static func readCapabilities(_ channel: DeviceProbeChannel) -> DeviceReport.CapabilitiesData {
        DeviceReport.CapabilitiesData(reads: capabilityReads.map { name, report in
            var read = DeviceReport.CapabilityRead(
                name: name, commandClass: report.commandClass, commandId: report.commandId,
                led: report.commandClass == 0x0F ? report.arguments[1] : nil, answer: .noAnswer)
            do {
                let answer = try channel.sendWithRetry(report, attempts: 1)
                read.answer = .answered
                read.response = Array(answer.arguments.prefix(capabilityResponseBytes))
            } catch HIDDevice.HIDError.commandFailed {
                read.answer = .failed
            } catch HIDDevice.HIDError.notSupported {
                read.answer = .notSupported
            } catch {
                read.answer = .noAnswer
            }
            return read
        })
    }

    static func battery(_ channel: DeviceProbeChannel, expectsBattery: Bool?)
        -> DeviceReport.StepRecord<DeviceReport.BatteryData> {
        var record = DeviceReport.StepRecord<DeviceReport.BatteryData>()
        var data = DeviceReport.BatteryData()
        do {
            let level = try DeviceProbe.battery(channel)
            data.raw = level.value
            data.percent = RazerCommands.batteryPercent(fromRaw: level.value)
            data.charging = try? DeviceProbe.charging(channel).value
            // Raw 0 is the protocol's "not ready" (just woken, or refusing around sleep), not
            // an empty battery, so it doesn't pass.
            record.outcome = level.value == 0 ? .failed : .passed
        } catch {
            record.error = String(describing: error)
            record.outcome = DeviceProbe.isRefusal(error) && expectsBattery != true ? .notSupported : .failed
        }
        record.data = data
        return record
    }

    /// Writes a test DPI 50 away from the current one, reads it back, and restores. Reads the
    /// stage table. `maxProbe` also asks for the protocol's ceiling to see what the mouse
    /// keeps, then restores again.
    static func dpi(_ channel: DeviceProbeChannel, maxProbe: Bool) -> DeviceReport.StepRecord<DeviceReport.DPIData> {
        var record = DeviceReport.StepRecord<DeviceReport.DPIData>()
        var data = DeviceReport.DPIData()
        do {
            let original = try DeviceProbe.readDPI(channel).value
            data.original = Int(original.x)
            let test = original.x > 150 ? original.x - 50 : original.x + 50
            data.test = Int(test)
            var wrote = false
            defer {
                // On every path, including a failed read-back: the user's DPI goes back.
                if wrote { data.restored = (try? DeviceProbe.writeDPI(channel, original).confirmed) ?? false }
            }
            wrote = true
            let check = try DeviceProbe.writeDPI(channel, .init(x: test, y: test))
            data.readBack = Int(check.readBack.value.x)
            if maxProbe {
                // nil, not 0, when the probe got no answer: 0 would read as a real ceiling.
                data.maxProbe = (try? DeviceProbe.writeDPI(channel, .init(x: 45000, y: 45000))).map { Int($0.readBack.value.x) }
            }
            if let table = try? DeviceProbe.readStages(channel) {
                data.stages = table.value.stages
                data.activeStageByte = table.value.activeByte
                if !table.value.stages.isEmpty { data.firstStageNumber = Int(table.response.arguments[3]) }
            }
            record.outcome = check.confirmed ? .passed : .failed
        } catch {
            record.error = String(describing: error)
            record.outcome = .failed
        }
        // The restore runs as the `do` scope above ends, so `data.restored` is final here.
        if record.outcome == .passed, !data.restored { record.outcome = .failed }
        record.data = data
        return record
    }

    /// Writes another supported rate, reads it back, and restores.
    static func polling(_ channel: DeviceProbeChannel) -> DeviceReport.StepRecord<DeviceReport.PollingData> {
        var record = DeviceReport.StepRecord<DeviceReport.PollingData>()
        var data = DeviceReport.PollingData()
        do {
            let original = try DeviceProbe.readPollingRate(channel).value
            data.original = original
            // A rate the table doesn't name (0) can't be written back, so don't change it.
            guard original != 0 else {
                record.outcome = .failed
                record.error = "The mouse reported a polling rate the protocol table doesn't name."
                record.data = data
                return record
            }
            let test = original == 500 ? 1000 : 500
            data.test = test
            var wrote = false
            defer { if wrote { data.restored = (try? DeviceProbe.writePollingRate(channel, hz: original).confirmed) ?? false } }
            wrote = true
            let check = try DeviceProbe.writePollingRate(channel, hz: test)
            data.readBack = check.readBack.value
            record.outcome = check.confirmed ? .passed : .failed
        } catch {
            record.error = String(describing: error)
            record.outcome = DeviceProbe.isRefusal(error) ? .notSupported : .failed
        }
        if record.outcome == .passed, !data.restored { record.outcome = .failed }
        record.data = data
        return record
    }

    /// Two checks a person can see. First every group that answered goes dark for `seconds`
    /// and comes back to its exact brightness. Then, if `restoreEffect` is given, the mouse
    /// turns red at full brightness for `seconds` and goes back to `restoreEffect` (the app's
    /// own setting: an effect can't be read back) and to each group's brightness. The
    /// questions come afterwards, so nothing is held waiting on the person.
    static func lighting(_ channel: DeviceProbeChannel, sweep: [DeviceProbe.LEDAnswer]?,
                         restoreEffect: RazerReport?, seconds: Double,
                         wait: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) })
        -> DeviceReport.StepRecord<DeviceReport.LightingData> {
        var record = DeviceReport.StepRecord<DeviceReport.LightingData>()
        var data = DeviceReport.LightingData()
        let answering = (sweep ?? []).compactMap { answer -> (String, UInt8, UInt8)? in
            guard let reading = try? answer.result.get() else { return nil }
            return (answer.name, answer.led, reading.value)
        }
        guard !answering.isEmpty else {
            record.outcome = .notSupported
            record.data = data
            return record
        }
        for (name, _, raw) in answering { data.groups[name] = raw }

        // Nothing from here to the restore can leave early (every call is `try?`), so the
        // restore always runs once anything has been changed.
        var dimmedAny = false
        for (_, led, _) in answering {
            dimmedAny = (try? DeviceProbe.writeBrightness(channel, raw: 0, led: led)) != nil || dimmedAny
        }
        data.dimShown = dimmedAny
        if dimmedAny { wait(seconds) }
        var allBack = restoreBrightness(channel, answering)

        if let restoreEffect {
            for (_, led, _) in answering { _ = try? DeviceProbe.writeBrightness(channel, raw: 255, led: led) }
            data.redShown = (try? DeviceProbe.applyLighting(channel, RazerCommands.setStatic(rgb: RGB(r: 255, g: 0, b: 0)))) != nil
            if data.redShown { wait(seconds) }
            let effectBack = (try? DeviceProbe.applyLighting(channel, restoreEffect)) != nil
            allBack = restoreBrightness(channel, answering) && effectBack && allBack
        }
        data.restored = allBack

        // The outcome needs the person's answers; `answered(dimmed:turnedRed:_:)` sets it.
        record.outcome = data.dimShown ? .skipped : .failed
        record.data = data
        return record
    }

    private static func restoreBrightness(_ channel: DeviceProbeChannel, _ groups: [(String, UInt8, UInt8)]) -> Bool {
        var allBack = true
        for (_, led, raw) in groups {
            allBack = ((try? DeviceProbe.writeBrightness(channel, raw: raw, led: led).confirmed) ?? false) && allBack
        }
        return allBack
    }

    /// Folds the person's answers into the lighting record. Passes only when every check that
    /// ran was seen and everything went back; any "no" fails it; any "not sure" leaves it
    /// untested, which is never a confirmation.
    static func answered(dimmed: Bool?, turnedRed: Bool?,
                         _ record: inout DeviceReport.StepRecord<DeviceReport.LightingData>) {
        guard var data = record.data, data.dimShown else { return }
        data.dimmed = dimmed
        data.turnedRed = data.redShown ? turnedRed : nil
        record.data = data
        let answers = data.redShown ? [dimmed, turnedRed] : [dimmed]
        if answers.contains(false) { record.outcome = .failed }
        else if answers.contains(where: { $0 == nil }) { record.outcome = .skipped }
        else { record.outcome = data.restored ? .passed : .failed }
    }

    /// A refusal (0x03) or not-supported (0x05) is the mouse saying no, as opposed to a
    /// timeout or a garbled answer, which say nothing about what it has.
}

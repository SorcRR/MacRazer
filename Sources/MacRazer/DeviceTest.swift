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
    static let currentSchema = 1

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
    var verdict: DeviceTestVerdict?
    var comment: String?
    /// How the person would like to be credited in the README, if at all.
    var credit: String?
    /// For a reply. Only ever sent to the maintainer; never put in a GitHub issue.
    var replyEmail: String?

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

    struct StepRecord<Data: Codable & Equatable>: Codable, Equatable {
        var outcome: Outcome = .skipped
        var data: Data?
        var error: String?
        var exchanges: [RecordingChannel.Exchange] = []
    }

    struct TransactionResult: Codable, Equatable {
        var id: UInt8
        var answered: Bool
        /// The groups that answered, for lighting attempts.
        var groups: [String]?
        var error: String?
    }

    struct IdentifyData: Codable, Equatable {
        var firmware: String?
        var standardAttempts: [TransactionResult]
        var lightingAttempts: [TransactionResult]
        var standardId: UInt8?
        var lightingId: UInt8?
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
                            _ step: (DeviceProbeChannel) -> DeviceReport.StepRecord<T>) -> DeviceReport.StepRecord<T> {
        let recording = RecordingChannel(base: device)
        var record = step(FixedTransactionChannel(base: recording, standard: standard, matrix: matrix))
        record.exchanges = recording.exchanges
        return record
    }

    /// Tries every transaction id, then reads the firmware with the one chosen.
    static func identify(_ device: TransactionChannel, registry: RazerDeviceInfo?)
        -> (record: DeviceReport.StepRecord<DeviceReport.IdentifyData>, sweep: [DeviceProbe.LEDAnswer]?) {
        let recording = RecordingChannel(base: device)
        let standard = DeviceProbe.discoverTransactionIds(recording, read: RazerCommands.getFirmwareVersion(),
                                                          preferred: registry?.transactionId)
        let standardId = DeviceProbe.chosenId(standard)
        let lighting = DeviceProbe.discoverMatrixTransactionIds(recording, standard: standardId ?? 0x1F,
                                                                preferred: registry?.matrixTransactionId)
        let lightingId = DeviceProbe.chosenId(lighting)

        var data = DeviceReport.IdentifyData(
            standardAttempts: standard.map {
                .init(id: $0.id, answered: $0.answered, groups: nil,
                      error: { if case .failure(let e) = $0.result { return String(describing: e) }; return nil }($0))
            },
            lightingAttempts: lighting.map { .init(id: $0.id, answered: $0.answered, groups: $0.answeredGroups, error: nil) },
            standardId: standardId, lightingId: lightingId)
        if let standardId {
            data.firmware = try? DeviceProbe.firmware(
                FixedTransactionChannel(base: recording, standard: standardId, matrix: lightingId ?? standardId)).value
        }

        // Failed when nothing answered at all, or when a known model didn't answer to the id
        // on record: that is exactly the regression a confirmation exists to catch.
        var outcome: DeviceReport.Outcome = standardId == nil ? .failed : .passed
        if let registry, !standard.contains(where: { $0.id == registry.transactionId && $0.answered }) {
            outcome = .failed
        }
        let sweep = lighting.first(where: { $0.id == lightingId })?.sweep
        return (.init(outcome: outcome, data: data, exchanges: recording.exchanges), sweep)
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
            record.outcome = refusedOutright(error) && expectsBattery != true ? .notSupported : .failed
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
                data.maxProbe = Int((try? DeviceProbe.writeDPI(channel, .init(x: 45000, y: 45000)))?.readBack.value.x ?? 0)
            }
            data.stages = try? DeviceProbe.readStages(channel).value.stages
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
            record.outcome = refusedOutright(error) ? .notSupported : .failed
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
    private static func refusedOutright(_ error: Error) -> Bool {
        switch error {
        case HIDDevice.HIDError.commandFailed, HIDDevice.HIDError.notSupported: return true
        default: return false
        }
    }
}

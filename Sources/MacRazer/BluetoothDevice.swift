// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import CoreBluetooth

/// A Razer mouse reached over Bluetooth LE, through the vendor GATT service described in
/// `BLEProtocol`. Same surface as `HIDDevice`, so `MouseController` doesn't care which.
///
/// Threading: CoreBluetooth calls back on `queue`, and all GATT state lives there. Callers
/// (MouseController's `io` queue) block on a semaphore while a request runs, never on
/// `queue` itself, so callbacks stay free to complete it.
///
/// Only opened for a mouse macOS already has connected as a Bluetooth HID device, and only
/// for a product id the registry lists as `.bluetooth`. That pre-check runs on IOHID, so
/// nobody without such a mouse ever creates a `CBCentralManager` or sees the Bluetooth
/// permission prompt.
final class BluetoothDevice: NSObject, RazerTransport, @unchecked Sendable {
    let productID: Int
    let productName: String
    let locationID = 0
    let isBluetooth = true

    private let queue = DispatchQueue(label: "com.macrazer.bluetooth")
    private let service = CBUUID(string: BLEProtocol.serviceUUID)
    private let writeUUID = CBUUID(string: BLEProtocol.writeUUID)
    private let notifyUUID = CBUUID(string: BLEProtocol.notifyUUID)
    private let auxiliaryUUID = CBUUID(string: BLEProtocol.auxiliaryUUID)
    private let deviceInfoService = CBUUID(string: "180A")
    private let pnpIDUUID = CBUUID(string: "2A50")

    // `queue` only.
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyReady = false
    private var pnpChecked = false
    private var onStateChange: (() -> Void)?
    private var pending: Exchange?
    /// Characteristics the gesture trace asked to read, so their values log as reads.
    private var tracedReads: Set<CBUUID> = []

    // `io` only (the caller's queue).
    private var nextID: UInt8 = 0x30

    /// One request in flight: the frames still to write and the reply being assembled.
    /// An exchange sent once (`lenientExchange`) collects its reply in `trace` instead.
    private final class Exchange: @unchecked Sendable {
        var frames: [Data]
        var assembler: BLEProtocol.Assembler
        var trace: BLEProtocol.TraceAssembler?
        let done = DispatchSemaphore(value: 0)
        var error: Error?
        var finished = false
        init(frames: [Data], id: UInt8, traced: Bool = false) {
            self.frames = frames
            self.assembler = BLEProtocol.Assembler(id: id)
            self.trace = traced ? BLEProtocol.TraceAssembler(id: id) : nil
        }
    }

    /// Time allowed for Bluetooth to report its state, then for the GATT setup.
    static let poweredOnTimeout: TimeInterval = 3
    static let connectTimeout: TimeInterval = 5
    /// One request, from the first write to the last reply byte. Replies measured on the
    /// Cobra HyperSpeed arrive within tens of milliseconds; this leaves room for a mouse
    /// waking from its idle state.
    static let requestTimeout: TimeInterval = 1.5

    private init(productID: Int, productName: String) {
        self.productID = productID
        self.productName = productName
        super.init()
    }

    /// Connect to the vendor service of the Bluetooth mouse `pid` names. Throws `notFound`
    /// when Bluetooth is off or not allowed, the mouse isn't connected to this Mac, or it
    /// doesn't expose the service.
    static func open(pid: Int, hidName: String) throws -> BluetoothDevice {
        let name = RazerDevices.info(pid: pid)?.name ?? hidName
        let device = BluetoothDevice(productID: pid, productName: name)
        do {
            try device.connect(hidName: hidName)
        } catch {
            device.close()
            throw error
        }
        return device
    }

    private func connect(hidName: String) throws {
        // Denied is final until the user changes it in System Settings. Checking first keeps
        // every poll from spinning up a central manager just to be told no.
        if [.denied, .restricted].contains(CBManager.authorization) { throw HIDDevice.HIDError.notFound }
        let poweredOn = DispatchSemaphore(value: 0)
        queue.sync {
            onStateChange = { poweredOn.signal() }
            central = CBCentralManager(delegate: self, queue: queue)
        }
        guard poweredOn.wait(timeout: .now() + Self.poweredOnTimeout) == .success,
              queue.sync(execute: { central?.state == .poweredOn }) else {
            throw HIDDevice.HIDError.notFound
        }

        let ready = DispatchSemaphore(value: 0)
        let found: Bool = queue.sync {
            guard let central else { return false }
            // The mouse is already connected to macOS as a HID device; ask for that
            // connection rather than scanning. Prefer the one whose name matches the HID
            // device, in case two Razer mice are paired.
            let candidates = central.retrieveConnectedPeripherals(withServices: [service])
            guard let match = candidates.first(where: { $0.name == hidName }) ?? candidates.first else {
                return false
            }
            onStateChange = { [weak self] in
                guard let self, self.notifyReady, self.pnpChecked else { return }
                ready.signal()
            }
            peripheral = match
            match.delegate = self
            central.connect(match)
            return true
        }
        guard found else { throw HIDDevice.HIDError.notFound }
        guard ready.wait(timeout: .now() + Self.connectTimeout) == .success else {
            throw HIDDevice.HIDError.notFound
        }
        queue.sync { onStateChange = nil }
    }

    // MARK: - RazerTransport

    func sendWithRetry(_ report: RazerReport) throws -> RazerReport {
        try RazerRetry.run(attempts: HIDDevice.defaultAttempts) { try send(report) }
    }

    private func send(_ report: RazerReport) throws -> RazerReport {
        // Selecting a DPI rewrites the whole stage table, so start from the mouse's current
        // one: a cached copy could be older than a change made on the mouse or elsewhere,
        // and writing it back would quietly revert that.
        let isDPISelect = report.commandClass == 0x04 && report.commandId == 0x05
        let current = isDPISelect ? try readStages() : nil
        guard let request = BLEProtocol.request(for: report, stages: current) else {
            throw HIDDevice.HIDError.notSupported
        }
        let payload = try exchange(request)
        if request.key == .dpiStagesSet {
            // A write acknowledgement only says the frames arrived. Read the table back
            // and compare, the way the CLI confirms a DPI write over USB.
            let written = try BLEProtocol.DPIStageTable(decoding: request.payload)
            guard try readStages() == written else { throw HIDDevice.HIDError.commandFailed }
        }
        return try BLEProtocol.response(to: report, reply: request.reply, payload: payload)
    }

    private func readStages() throws -> BLEProtocol.DPIStageTable {
        let request = BLEProtocol.Request(key: .dpiStagesGet, payload: [], reply: .dpiStages)
        return try BLEProtocol.DPIStageTable(decoding: Array(exchange(request)))
    }

    func readDpiStages() throws -> BLEProtocol.DPIStageTable {
        try RazerRetry.run(attempts: HIDDevice.defaultAttempts) { try readStages() }
    }

    func setDpiStages(_ stages: BLEProtocol.DPIStageTable) throws {
        let request = BLEProtocol.Request(key: .dpiStagesSet, payload: stages.encoded(), reply: .ack)
        try RazerRetry.run(attempts: HIDDevice.defaultAttempts) {
            _ = try exchange(request)
            guard try readStages() == stages else { throw HIDDevice.HIDError.commandFailed }
        }
    }

    func readSleepTimeout() throws -> Int {
        let request = BLEProtocol.Request(key: .powerTimeoutGet, payload: [], reply: .ack)
        let payload = try RazerRetry.run(attempts: HIDDevice.defaultAttempts) { try exchange(request) }
        return try BLEProtocol.parseSleepTimeout(payload)
    }

    func setSleepTimeout(_ seconds: Int) throws {
        guard let payload = BLEProtocol.sleepTimeoutPayload(seconds: seconds) else {
            throw HIDDevice.HIDError.notSupported
        }
        let request = BLEProtocol.Request(key: .powerTimeoutSet, payload: Array(payload), reply: .ack)
        try RazerRetry.run(attempts: HIDDevice.defaultAttempts) {
            _ = try exchange(request)
            guard try BLEProtocol.parseSleepTimeout(exchange(BLEProtocol.Request(key: .powerTimeoutGet, payload: [], reply: .ack))) == seconds else {
                throw HIDDevice.HIDError.commandFailed
            }
        }
    }

    /// Read the DPI button's assignment (entry 0x60, on a mouse with
    /// `RazerDevices.supportsDpiButtonBinding`). This is a control layered on the shared BLE
    /// framing; ordinary Razer reports continue to use `sendWithRetry` above. Throws
    /// `BLEProtocol.DPIButtonEntryError` for a reply this app doesn't understand.
    func readDpiCycleBinding() throws -> BLEProtocol.DPIButtonBinding {
        try BLEProtocol.parseDpiButtonBinding(readDpiCycleEntry())
    }

    /// Entry 0x60 as the mouse sent it, retried like the other reads.
    private func readDpiCycleEntry() throws -> Data {
        let request = BLEProtocol.Request(key: .dpiButtonGet, payload: [], reply: .ack)
        return try RazerRetry.run(attempts: HIDDevice.defaultAttempts) { try exchange(request) }
    }

    /// Write the DPI button's assignment (`writeDpiCycleBinding`). A software action is the
    /// reserved F20 keyboard usage, which ButtonRemapper turns into the action while this app
    /// is running.
    func setDpiCycleBinding(_ binding: BLEProtocol.DPIButtonBinding) throws {
        try Self.writeDpiCycleBinding(binding, activeSlot: { readActiveSlot() }, read: { try readDpiCycleEntry() },
                                      write: { payload in
            _ = try exchange(BLEProtocol.Request(key: .dpiButtonSet, payload: payload, reply: .ack))
        })
    }

    /// The DPI button's write, apart from the device so tests can drive it: `activeSlot`
    /// returns the profile slot in use (`readActiveSlot`), `read` a read of entry 0x60,
    /// `write` sends the set payload.
    ///
    /// The write goes to profile 1 (`BLEProtocol.Key.dpiButtonSet`), and the reads before and
    /// after it read the profile in use. So nothing is sent while the mouse says another
    /// profile is in use (`DPIButtonEntryError.otherProfileInUse`): the reads would check one
    /// profile's entry and the write change another's, which nothing read and the page never
    /// shows. A mouse that doesn't say is taken to be on profile 1, as before.
    ///
    /// The entry is read first, and nothing is written unless that read succeeds and parses
    /// (`BLEProtocol.parseDpiButtonBinding`): the binding is enabled on a model where 0x60 is
    /// not yet confirmed on hardware (the Cobra HyperSpeed), and a write must never land on an
    /// entry that isn't the DPI button or holds something this app can't put back. That read's
    /// errors are thrown unchanged, so they always mean nothing was written. The write itself
    /// is sent once. Then the entry is read again, and anything but `binding` throws
    /// `DPIButtonWriteError.notReadBack`; no second write follows a mismatch.
    static func writeDpiCycleBinding(_ binding: BLEProtocol.DPIButtonBinding, activeSlot: () -> UInt8,
                                     read: () throws -> Data, write: ([UInt8]) throws -> Void) throws {
        let slot = activeSlot()
        guard slot == BLEProtocol.Key.dpiButtonSet.bytes[2] else {
            throw BLEProtocol.DPIButtonEntryError.otherProfileInUse(slot)
        }
        _ = try BLEProtocol.parseDpiButtonBinding(read())
        do {
            try write(Array(BLEProtocol.dpiButtonPayload(for: binding)))
        } catch {
            throw BLEProtocol.DPIButtonWriteError.notTaken
        }
        guard (try? BLEProtocol.parseDpiButtonBinding(read())) == binding else {
            throw BLEProtocol.DPIButtonWriteError.notReadBack
        }
    }

    /// One entry of the mouse's function table, as the mouse sent it (`id, flag`, then the
    /// current and factory blocks interleaved; `BLEProtocol.parseButtonFunction`).
    /// Slot 0 is the slot in use.
    func readButtonFunctionPayload(_ id: UInt8, slot: UInt8 = 0x00) throws -> Data {
        let request = BLEProtocol.Request(key: .buttonFunctionGet(id, slot: slot), payload: [], reply: .ack)
        return try RazerRetry.run(attempts: HIDDevice.defaultAttempts) { try exchange(request) }
    }

    /// The onboard profile slot in use, or 1 when the mouse doesn't say (the slot the DPI
    /// button's write goes to, `BLEProtocol.Key.dpiButtonSet`). Retried, so one lost reply
    /// doesn't send a write to the wrong slot.
    func readActiveSlot() -> UInt8 {
        let request = BLEProtocol.Request(key: .activeSlotGet, payload: [], reply: .ack)
        guard let payload = try? RazerRetry.run(attempts: HIDDevice.defaultAttempts, { try exchange(request) }),
              let slot = payload.first, (1...5).contains(slot) else { return 0x01 }
        return slot
    }

    /// Puts a side button's factory block back in each profile slot that holds its remap
    /// (`SideButtonReset.slotsToReset`), then reads every written slot and the slot in use back.
    /// Returns the slots written.
    ///
    /// Every slot is read before anything is written, and only slots whose read matches the
    /// remap exactly are written. Only the write exchanges are retried. The read-backs run
    /// once, and a mismatch is never followed by another write.
    func resetButtonFunction(_ remap: SideButtonReset.Remap) throws -> [UInt8] {
        let active = readActiveSlot()
        var reads: [UInt8: Data] = [:]
        for slot in SideButtonReset.slots {
            // A slot the mouse refuses to read holds nothing this reset can confirm.
            if let payload = try? readButtonFunctionPayload(remap.id, slot: slot) { reads[slot] = payload }
        }
        let targets = try SideButtonReset.slotsToReset(remap, activeSlot: active, slotPayloads: reads)
        for (index, slot) in targets.enumerated() {
            let request = BLEProtocol.Request(key: .buttonFunctionSet(remap.id, slot: slot),
                                              payload: BLEProtocol.buttonFunctionPayload(id: remap.id, block: remap.factory, slot: slot),
                                              reply: .ack)
            do {
                try RazerRetry.run(attempts: HIDDevice.defaultAttempts) { _ = try exchange(request) }
            } catch where index > 0 {
                // Earlier slots already took the reset, so don't say nothing changed.
                throw SideButtonReset.ResetError.partlyWritten
            }
        }
        for slot in targets + [0x00] {
            guard try BLEProtocol.parseButtonFunction(id: remap.id, readButtonFunctionPayload(remap.id, slot: slot)).current == remap.factory else {
                throw SideButtonReset.ResetError.notReadBack
            }
        }
        return targets
    }

    /// `io` only. The next request id.
    private func takeID() -> UInt8 {
        let id = nextID
        // Stay clear of 0x00 and 0x01: the mouse uses 0x01 for its unsolicited frame.
        nextID = nextID >= 0xEF ? 0x30 : nextID + 1
        return id
    }

    private func exchange(_ request: BLEProtocol.Request) throws -> Data {
        let id = takeID()
        let exchange = Exchange(frames: BLEProtocol.frames(id: id, request: request), id: id)
        queue.async { self.start(exchange) }
        guard exchange.done.wait(timeout: .now() + Self.requestTimeout) == .success else {
            queue.sync { if self.pending === exchange { self.pending = nil } }
            throw HIDDevice.HIDError.timeout
        }
        if let error = exchange.error { throw error }
        return try exchange.assembler.result()
    }

    // MARK: - Device mode

    /// The mouse's device mode, as the u16 it answers with (`BLEProtocol.parseDeviceMode`):
    /// 0 normal, 3 driver. Sent once, never retried (`lenientExchange`).
    func readDeviceMode() throws -> UInt16 {
        let reply = lenientExchange(BLEProtocol.deviceModeReadRequest)
        GestureDebugLog.log("DEVMODE read 01 82 00 00 -> \(reply.text)")
        guard let value = try BLEProtocol.parseDeviceMode(reply.payload()) else {
            throw HIDDevice.HIDError.badResponse
        }
        return value
    }

    /// Sends the device-mode write once (`BLEProtocol.deviceModeRequest`). Throws unless the
    /// mouse answers it with success.
    func writeDeviceMode(_ mode: BLEProtocol.DeviceMode) throws {
        let request = BLEProtocol.deviceModeRequest(mode)
        let reply = lenientExchange(request)
        GestureDebugLog.log("DEVMODE write 01 02 00 00 [\(GestureDebugLog.hex(request.payload))] -> \(reply.text)")
        _ = try reply.payload()
    }

    /// Puts the mouse in `mode` (`setDeviceMode(_:readFirst:read:write:)`).
    @discardableResult
    func setDeviceMode(_ mode: BLEProtocol.DeviceMode, readFirst: Bool,
                       beforeWrite: () -> Void = {}) throws -> DeviceModeChange {
        try Self.setDeviceMode(mode, readFirst: readFirst, read: { try readDeviceMode() }, write: { mode in
            beforeWrite()
            try writeDeviceMode(mode)
        })
    }

    /// What `setDeviceMode` did.
    enum DeviceModeChange: Equatable, Sendable {
        /// The read before showed the mouse already in the mode, so nothing was written.
        case alreadySet
        /// The mode was written once and read back.
        case written
    }

    /// The device-mode change, apart from the device so tests can drive it: `read` reads the
    /// mode (`readDeviceMode`), `write` sends the write (`writeDeviceMode`).
    ///
    /// With `readFirst` the mode is read before anything is written, and a mouse already in
    /// `mode` is left alone; a read that fails then throws `unreadable`, and nothing was
    /// written. The write is sent once. Then the mode is read back, and anything but `mode`
    /// throws `notReadBack`; no second write follows. Without `readFirst` (going back to normal
    /// mode, which is harmless to write again) the write goes first.
    static func setDeviceMode(_ mode: BLEProtocol.DeviceMode, readFirst: Bool,
                              read: () throws -> UInt16,
                              write: (BLEProtocol.DeviceMode) throws -> Void) throws -> DeviceModeChange {
        if readFirst {
            guard let current = try? read() else { throw BLEProtocol.DeviceModeError.unreadable }
            if current == mode.value { return .alreadySet }
        }
        do {
            try write(mode)
        } catch {
            throw BLEProtocol.DeviceModeError.notTaken
        }
        let back = try? read()
        guard back == mode.value else { throw BLEProtocol.DeviceModeError.notReadBack(back) }
        return .written
    }

    // MARK: - Exchanges sent once (device mode, gesture trace)

    /// What one `lenientExchange` came back with.
    struct LenientReply: Sendable {
        let reply: BLEProtocol.TraceAssembler?
        let timedOut: Bool
        /// Why it never went out, or the link went away during it.
        let error: (any Error)?

        /// The mouse answered with success, in time.
        var succeeded: Bool { error == nil && !timedOut && reply?.isSuccess == true }

        /// The payload up to its declared length, or the error the reply stands for.
        func payload() throws -> [UInt8] {
            if let error { throw error }
            guard let reply, !timedOut, reply.isComplete else { throw HIDDevice.HIDError.timeout }
            switch BLEProtocol.Status(rawValue: reply.status ?? 0) {
            case .ok: return Array(reply.payload.prefix(reply.declaredLength))
            case .notSupported: throw HIDDevice.HIDError.notSupported
            case .failure, nil: throw HIDDevice.HIDError.commandFailed
            }
        }

        /// How the gesture trace logs it (`GestureDebugLog.describe`).
        var text: String {
            if let error { return "failed: \(error)" }
            guard let reply else { return "no reply" }
            return GestureDebugLog.describe(reply, timedOut: timedOut)
        }
    }

    /// Longer than `requestTimeout`: a trace read may bring back a reply larger than any the
    /// app asks for (every binding at once).
    static let traceRequestTimeout: TimeInterval = 2
    /// How long a refusal waits for a success for the same request (`TraceAssembler`).
    static let traceRefusalGrace: TimeInterval = 0.25

    /// One read for the gesture trace (`GestureDebugLog`). Only a key with the read bit is
    /// sent (`BLEProtocol.traceReadRequest`). Never throws: a failure is the result's text.
    func traceRead(_ key: BLEProtocol.Key) -> String {
        guard let request = BLEProtocol.traceReadRequest(key) else { return "not sent: not a read key" }
        return lenientExchange(request).text
    }

    /// One exchange on the caller's queue like every other: sent once, never retried, its
    /// reply kept whole (`BLEProtocol.TraceAssembler`). A refusal waits a moment for a success
    /// for the same request, as some Razer firmware sends one after the other. This is how
    /// the device mode was first read and written on hardware, and both still go this way.
    private func lenientExchange(_ request: BLEProtocol.Request) -> LenientReply {
        let id = takeID()
        let exchange = Exchange(frames: BLEProtocol.frames(id: id, request: request), id: id, traced: true)
        queue.async { self.start(exchange) }
        _ = exchange.done.wait(timeout: .now() + Self.traceRequestTimeout)
        return queue.sync {
            // Read here, where frames arrive, so a late one can't land halfway through.
            let timedOut = !exchange.finished
            if self.pending === exchange { self.pending = nil }
            return LenientReply(reply: exchange.trace, timedOut: timedOut, error: exchange.error)
        }
    }

    /// `queue` only. A frame went into a lenient exchange's reply: finish on success, and on a
    /// refusal after a short wait, in case the success for the same request follows.
    private func traceFrameTaken(_ exchange: Exchange) {
        guard let reply = exchange.trace, reply.isComplete else { return }
        if reply.isSuccess { finish(exchange, error: nil); return }
        let replaced = reply.replacedStatuses.count
        queue.asyncAfter(deadline: .now() + Self.traceRefusalGrace) { [weak self] in
            guard let self, self.pending === exchange,
                  exchange.trace?.replacedStatuses.count == replaced else { return }
            self.finish(exchange, error: nil)
        }
    }

    /// `queue` only. Logs a value that isn't part of a reply being assembled.
    private func traceUnsolicited(_ characteristic: CBCharacteristic, _ value: Data) {
        guard GestureDebugLog.enabled else { return }
        let kind = tracedReads.remove(characteristic.uuid) != nil ? "read" : "unsolicited"
        GestureDebugLog.log("BLE \(kind) \(characteristic.uuid.uuidString): \(GestureDebugLog.hex(value))")
    }

    /// `queue` only. Lists Razer's service as the mouse describes it, then subscribes to
    /// `BLEProtocol.auxiliaryUUID` (and reads it once) when the mouse has it.
    private func traceCharacteristics(of service: CBService, on peripheral: CBPeripheral) {
        let characteristics = service.characteristics ?? []
        for c in characteristics {
            GestureDebugLog.log("GATT \(c.uuid.uuidString) properties=\(Self.describe(c.properties))")
        }
        guard let auxiliary = characteristics.first(where: { $0.uuid == auxiliaryUUID }) else {
            GestureDebugLog.log("GATT \(BLEProtocol.auxiliaryUUID) not present")
            return
        }
        if !auxiliary.properties.isDisjoint(with: [.notify, .indicate]) {
            GestureDebugLog.log("GATT subscribing to \(BLEProtocol.auxiliaryUUID)")
            peripheral.setNotifyValue(true, for: auxiliary)
        }
        if auxiliary.properties.contains(.read) {
            tracedReads.insert(auxiliary.uuid)
            peripheral.readValue(for: auxiliary)
        }
    }

    /// A characteristic's properties by name, for the trace: "read,notify".
    static func describe(_ properties: CBCharacteristicProperties) -> String {
        let names: [(CBCharacteristicProperties, String)] = [
            (.broadcast, "broadcast"), (.read, "read"), (.writeWithoutResponse, "writeWithoutResponse"),
            (.write, "write"), (.notify, "notify"), (.indicate, "indicate"),
            (.authenticatedSignedWrites, "authenticatedSignedWrites"), (.extendedProperties, "extendedProperties"),
            (.notifyEncryptionRequired, "notifyEncryptionRequired"),
            (.indicateEncryptionRequired, "indicateEncryptionRequired"),
        ]
        let known = names.filter { properties.contains($0.0) }.map(\.1)
        let rest = properties.subtracting(CBCharacteristicProperties(names.map(\.0)))
        let all = known + (rest.isEmpty ? [] : [String(format: "0x%x", rest.rawValue)])
        return all.isEmpty ? "none" : all.joined(separator: ",")
    }

    func close() {
        queue.async { self.tearDown() }
    }

    /// `close`, returning once the connection is let go. For a caller about to connect to the
    /// same mouse itself (the device test), so the cancel can't land on its new connection.
    /// Never call it on `queue`.
    func closeAndWait() {
        queue.sync { tearDown() }
    }

    private func tearDown() {
        if let pending { finish(pending, error: HIDDevice.HIDError.notFound) }
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeCharacteristic = nil
        notifyReady = false
        central = nil
    }

    // MARK: - `queue` only

    private func start(_ exchange: Exchange) {
        guard pending == nil, notifyReady, let peripheral, peripheral.state == .connected,
              writeCharacteristic != nil else {
            finish(exchange, error: HIDDevice.HIDError.notFound)
            return
        }
        pending = exchange
        writeNextFrame()
    }

    private func writeNextFrame() {
        guard let exchange = pending, let peripheral, let writeCharacteristic,
              !exchange.frames.isEmpty else { return }
        peripheral.writeValue(exchange.frames.removeFirst(), for: writeCharacteristic, type: .withResponse)
    }

    private func finish(_ exchange: Exchange, error: Error?) {
        guard !exchange.finished else { return }
        exchange.finished = true
        exchange.error = error
        if pending === exchange { pending = nil }
        exchange.done.signal()
    }
}

// MARK: - CoreBluetooth delegates

extension BluetoothDevice: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Any settled state wakes `connect`, which then checks for `.poweredOn`.
        if central.state != .unknown && central.state != .resetting { onStateChange?() }
        if central.state != .poweredOn, let pending { finish(pending, error: HIDDevice.HIDError.notFound) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([service, deviceInfoService])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        notifyReady = false
        if let pending { finish(pending, error: HIDDevice.HIDError.notFound) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] where s.uuid == service || s.uuid == deviceInfoService {
            // The gesture trace asks for all of Razer's characteristics, to list them.
            let wanted = s.uuid == service ? (GestureDebugLog.enabled ? nil : [writeUUID, notifyUUID]) : [pnpIDUUID]
            peripheral.discoverCharacteristics(wanted, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case writeUUID: writeCharacteristic = c
            case notifyUUID: peripheral.setNotifyValue(true, for: c)
            case pnpIDUUID: peripheral.readValue(for: c)
            default: break
            }
        }
        if GestureDebugLog.enabled, service.uuid == self.service {
            traceCharacteristics(of: service, on: peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyUUID else {
            if GestureDebugLog.enabled {
                GestureDebugLog.log("GATT \(characteristic.uuid.uuidString) notifying=\(characteristic.isNotifying)"
                                    + (error.map { " error=\($0.localizedDescription)" } ?? ""))
            }
            return
        }
        notifyReady = error == nil && characteristic.isNotifying
        onStateChange?()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let pending else { return }
        if let error { finish(pending, error: error); return }
        writeNextFrame()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error, GestureDebugLog.enabled, characteristic.uuid != pnpIDUUID {
            tracedReads.remove(characteristic.uuid)
            GestureDebugLog.log("BLE \(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
        }
        guard let value = characteristic.value else { return }
        if characteristic.uuid == pnpIDUUID {
            // PnP ID: [vendorIdSource, vid_lo, vid_hi, pid_lo, pid_hi, ver_lo, ver_hi]. Only
            // talk to the mouse the caller asked for: a different Razer model on the same
            // service would get commands sized for the wrong device.
            let b = Array(value)
            let matches = b.count >= 5
                && Int(b[1]) | Int(b[2]) << 8 == BLEProtocol.vendorId
                && Int(b[3]) | Int(b[4]) << 8 == productID
            pnpChecked = matches
            if matches { onStateChange?() }
            return
        }
        guard characteristic.uuid == notifyUUID, let pending else {
            traceUnsolicited(characteristic, value)
            return
        }
        let taken: Bool
        if pending.trace != nil {
            taken = pending.trace?.add(value) ?? false
            if taken { traceFrameTaken(pending) }
        } else {
            taken = pending.assembler.add(value)
            if pending.assembler.isComplete { finish(pending, error: nil) }
        }
        // A frame that isn't this reply's: an earlier request's late answer, or the mouse's own.
        if !taken { traceUnsolicited(characteristic, value) }
    }
}

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

    // `io` only (the caller's queue).
    private var nextID: UInt8 = 0x30

    /// One request in flight: the frames still to write and the reply being assembled.
    private final class Exchange: @unchecked Sendable {
        var frames: [Data]
        var assembler: BLEProtocol.Assembler
        let done = DispatchSemaphore(value: 0)
        var error: Error?
        var finished = false
        init(frames: [Data], id: UInt8) {
            self.frames = frames
            self.assembler = BLEProtocol.Assembler(id: id)
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
        try RazerRetry.run(attempts: 3) { try send(report) }
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

    private func exchange(_ request: BLEProtocol.Request) throws -> Data {
        let id = nextID
        // Stay clear of 0x00 and 0x01: the mouse uses 0x01 for its unsolicited frame.
        nextID = nextID >= 0xEF ? 0x30 : nextID + 1
        let exchange = Exchange(frames: BLEProtocol.frames(id: id, request: request), id: id)
        queue.async { self.start(exchange) }
        guard exchange.done.wait(timeout: .now() + Self.requestTimeout) == .success else {
            queue.sync { if self.pending === exchange { self.pending = nil } }
            throw HIDDevice.HIDError.timeout
        }
        if let error = exchange.error { throw error }
        return try exchange.assembler.result()
    }

    func close() {
        queue.async {
            if let pending = self.pending { self.finish(pending, error: HIDDevice.HIDError.notFound) }
            if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
            self.peripheral = nil
            self.writeCharacteristic = nil
            self.notifyReady = false
            self.central = nil
        }
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
            peripheral.discoverCharacteristics(s.uuid == service ? [writeUUID, notifyUUID] : [pnpIDUUID], for: s)
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
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyUUID else { return }
        notifyReady = error == nil && characteristic.isNotifying
        onStateChange?()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let pending else { return }
        if let error { finish(pending, error: error); return }
        writeNextFrame()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
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
        guard characteristic.uuid == notifyUUID, let pending else { return }
        pending.assembler.add(value)
        if pending.assembler.isComplete { finish(pending, error: nil) }
    }
}

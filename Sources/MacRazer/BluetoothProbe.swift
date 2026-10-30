// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CoreBluetooth
import Foundation

/// One read over Razer's Bluetooth service: a `BLEProtocol.Key` in, the reply's payload out.
/// What `DeviceTestSteps`' Bluetooth reads need, so they're tested without a mouse.
protocol BluetoothReadChannel {
    func read(_ key: BLEProtocol.Key) throws -> Data
}

/// The device test's look at a mouse over Bluetooth: which GATT services it has, its PnP ID,
/// the standard battery level, and reads over Razer's service when it has one.
///
/// Its own connection, not `BluetoothDevice`: that one only opens a model the registry lists,
/// and only once the PnP ID matches it, where the test is for the mice it doesn't know. Reads
/// only, and frame ids from 0xF0 up, clear of `BluetoothDevice`'s 0x30-0xEF in case the app's
/// own connection to the same mouse is still subscribed.
final class BluetoothProbe: NSObject, BluetoothReadChannel, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.macrazer.bluetooth-probe")
    private let razerService = CBUUID(string: BLEProtocol.serviceUUID)
    private let writeUUID = CBUUID(string: BLEProtocol.writeUUID)
    private let notifyUUID = CBUUID(string: BLEProtocol.notifyUUID)
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let deviceInfoService = CBUUID(string: "180A")
    private let pnpIDUUID = CBUUID(string: "2A50")
    private let hidService = CBUUID(string: "1812")

    // `queue` only.
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyReady = false
    /// Discoveries, subscriptions and reads asked for and not yet answered, by what they're
    /// for, so a value the mouse pushes unasked can't count as an answer.
    private var outstanding: Set<CBUUID> = []
    private var onChange: (() -> Void)?
    private var data = DeviceReport.BluetoothData()
    private var pending: Exchange?
    private var nextID: UInt8 = 0xF0

    private final class Exchange: @unchecked Sendable {
        var frames: [Data]
        var assembler: BLEProtocol.Assembler
        let done = DispatchSemaphore(value: 0)
        var error: Error?
        init(frames: [Data], id: UInt8) {
            self.frames = frames
            assembler = BLEProtocol.Assembler(id: id)
        }
    }

    /// Long enough for the person to answer macOS's Bluetooth prompt the first time.
    static let permissionTimeout: TimeInterval = 60
    static let poweredOnTimeout: TimeInterval = 3
    static let setupTimeout: TimeInterval = 5
    static let requestTimeout: TimeInterval = 1.5

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
    }

    /// Connects to the Bluetooth mouse macOS lists as `hidName`, describes it, and runs `body`
    /// over Razer's service when the mouse has it. Blocks: call it off the main thread.
    static func describe<T>(hidName: String, _ body: (BluetoothReadChannel) -> T)
        -> (data: DeviceReport.BluetoothData, result: T?) {
        let probe = BluetoothProbe()
        defer { probe.close() }
        do {
            try probe.connect(hidName: hidName)
        } catch {
            var data = probe.queue.sync { probe.data }
            data.error = String(describing: error)
            return (data, nil)
        }
        let usable = probe.queue.sync { probe.writeCharacteristic != nil && probe.notifyReady }
        let result = usable ? body(probe) : nil
        return (probe.queue.sync { probe.data }, result)
    }

    private func connect(hidName: String) throws {
        let authorization = CBManager.authorization
        if [.denied, .restricted].contains(authorization) {
            throw ProbeError(description: "Bluetooth access is turned off for MacRazer in System Settings.")
        }
        let settled = DispatchSemaphore(value: 0)
        queue.sync {
            onChange = { settled.signal() }
            central = CBCentralManager(delegate: self, queue: queue)
        }
        let wait = authorization == .notDetermined ? Self.permissionTimeout : Self.poweredOnTimeout
        guard settled.wait(timeout: .now() + wait) == .success,
              queue.sync(execute: { central?.state == .poweredOn }) else {
            throw ProbeError(description: "Bluetooth is off, or MacRazer wasn't allowed to use it.")
        }

        let ready = DispatchSemaphore(value: 0)
        let found: Bool = queue.sync {
            guard let central else { return false }
            // Already connected to macOS as a HID device: ask for that connection by name.
            // The HID service brings every Bluetooth keyboard and mouse along, so the name has
            // to match, or the one candidate has to have Razer's service.
            let connected = central.retrieveConnectedPeripherals(
                withServices: [razerService, hidService, batteryService, deviceInfoService])
            let razer = central.retrieveConnectedPeripherals(withServices: [razerService])
            guard let match = connected.first(where: { $0.name == hidName }) ?? razer.first else { return false }
            onChange = { ready.signal() }
            peripheral = match
            match.delegate = self
            central.connect(match)
            return true
        }
        guard found else { throw ProbeError(description: "macOS didn't list \(hidName) as a connected Bluetooth device.") }
        // Whatever arrived by then is still worth reporting: a mouse with no battery service
        // or no PnP ID still says which services it has.
        if ready.wait(timeout: .now() + Self.setupTimeout) != .success {
            queue.sync { data.error = "The Bluetooth setup didn't finish in time." }
        }
        queue.sync { onChange = nil }
    }

    func read(_ key: BLEProtocol.Key) throws -> Data {
        let id = queue.sync { () -> UInt8 in
            let id = nextID
            nextID = nextID >= 0xFE ? 0xF0 : nextID + 1
            return id
        }
        let exchange = Exchange(frames: BLEProtocol.frames(id: id, request: .init(key: key, payload: [], reply: .ack)), id: id)
        queue.async { self.start(exchange) }
        guard exchange.done.wait(timeout: .now() + Self.requestTimeout) == .success else {
            queue.sync { if self.pending === exchange { self.pending = nil } }
            throw HIDDevice.HIDError.timeout
        }
        if let error = exchange.error { throw error }
        return try exchange.assembler.result()
    }

    private func close() {
        queue.sync {
            if let pending { finish(pending, error: HIDDevice.HIDError.notFound) }
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            peripheral = nil
            writeCharacteristic = nil
            central = nil
        }
    }

    // MARK: - `queue` only

    private func start(_ exchange: Exchange) {
        guard pending == nil, notifyReady, let peripheral, let writeCharacteristic else {
            finish(exchange, error: HIDDevice.HIDError.notFound)
            return
        }
        pending = exchange
        peripheral.writeValue(exchange.frames.removeFirst(), for: writeCharacteristic, type: .withResponse)
    }

    private func finish(_ exchange: Exchange, error: Error?) {
        exchange.error = error
        if pending === exchange { pending = nil }
        exchange.done.signal()
    }

    private func answered(_ uuid: CBUUID) {
        guard outstanding.remove(uuid) != nil else { return }
        if outstanding.isEmpty { onChange?() }
    }
}

// MARK: - CoreBluetooth delegates

extension BluetoothProbe: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .unknown && central.state != .resetting { onChange?() }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        data.error = "Couldn't connect over Bluetooth: \(error.map { String(describing: $0) } ?? "no reason given")"
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        notifyReady = false
        if let pending { finish(pending, error: HIDDevice.HIDError.notFound) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        data.services = services.map(\.uuid.uuidString)
        data.razerService = services.contains { $0.uuid == razerService }
        let wanted: [CBUUID: [CBUUID]] = [
            razerService: [writeUUID, notifyUUID], batteryService: [batteryLevelUUID], deviceInfoService: [pnpIDUUID],
        ]
        let asked = services.filter { wanted[$0.uuid] != nil }
        guard !asked.isEmpty else { onChange?(); return }
        outstanding.formUnion(asked.map(\.uuid))
        for service in asked { peripheral.discoverCharacteristics(wanted[service.uuid], for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case writeUUID: writeCharacteristic = c
            case notifyUUID: outstanding.insert(c.uuid); peripheral.setNotifyValue(true, for: c)
            case batteryLevelUUID, pnpIDUUID: outstanding.insert(c.uuid); peripheral.readValue(for: c)
            default: break
            }
        }
        answered(service.uuid)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyUUID else { return }
        notifyReady = error == nil && characteristic.isNotifying
        answered(characteristic.uuid)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let pending else { return }
        if let error { finish(pending, error: error); return }
        if !pending.frames.isEmpty, let writeCharacteristic {
            peripheral.writeValue(pending.frames.removeFirst(), for: writeCharacteristic, type: .withResponse)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let bytes = characteristic.value.map(Array.init) ?? []
        switch characteristic.uuid {
        case batteryLevelUUID:
            if error == nil, let level = bytes.first, level <= 100 { data.batteryLevel = Int(level) }
            answered(characteristic.uuid)
        case pnpIDUUID:
            // [vendorIdSource, vid_lo, vid_hi, pid_lo, pid_hi, ver_lo, ver_hi]
            if error == nil, bytes.count >= 7 {
                data.pnpVendorID = Int(bytes[1]) | Int(bytes[2]) << 8
                data.pnpProductID = Int(bytes[3]) | Int(bytes[4]) << 8
                data.pnpVersion = Int(bytes[5]) | Int(bytes[6]) << 8
            }
            answered(characteristic.uuid)
        case notifyUUID:
            guard let pending, let value = characteristic.value else { return }
            pending.assembler.add(value)
            if pending.assembler.isComplete { finish(pending, error: nil) }
        default:
            break
        }
    }
}

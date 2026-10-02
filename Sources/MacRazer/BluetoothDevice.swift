// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import CoreBluetooth

/// CoreBluetooth adapter for the Basilisk V3 X HyperSpeed only. All CoreBluetooth delegate
/// callbacks run on a private serial queue; synchronous callers wait from MouseController's
/// separate I/O queue, so callbacks remain free to complete.
final class BluetoothDevice: NSObject, @unchecked Sendable, RazerControlTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let queue = DispatchQueue(label: "com.macrazer.bluetooth")
    private let service = CBUUID(string: BLEVendorProtocol.serviceUUID)
    private let writeUUID = CBUUID(string: BLEVendorProtocol.writeUUID)
    private let notifyUUID = CBUUID(string: BLEVendorProtocol.notifyUUID)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var isReady = false
    private var isPoweredOn = false
    private var activeRequest: UInt8 = 0
    private var requestID: UInt8 = 0x30
    private var notifications: [Data] = []
    private var writes: [Data] = []
    private var responseTimer: DispatchWorkItem?
    private var completion: ((Result<[Data], Error>) -> Void)?
    private var dpiSnapshot: BLEVendorProtocol.DpiSnapshot?
    private let readySemaphore = DispatchSemaphore(value: 0)
    private var hasPeripheral = false

    private final class ExchangeResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<[Data], Error> = .failure(HIDDevice.HIDError.timeout)
        func set(_ result: Result<[Data], Error>) { lock.lock(); stored = result; lock.unlock() }
        func get() -> Result<[Data], Error> { lock.lock(); defer { lock.unlock() }; return stored }
    }

    let productID = 0x00BA
    let productName: String
    let locationID: Int
    let isBluetooth = true

    private init(productName: String) {
        self.productName = productName
        self.locationID = 0
        super.init()
        queue.async { self.central = CBCentralManager(delegate: self, queue: self.queue) }
    }

    static func open(productName: String) throws -> BluetoothDevice {
        let device = BluetoothDevice(productName: productName)
        guard device.readySemaphore.wait(timeout: .now() + 5) == .success, device.isPoweredOn else {
            throw HIDDevice.HIDError.notFound
        }
        let connected = DispatchSemaphore(value: 0)
        device.queue.async {
            guard let central = device.central else { connected.signal(); return }
            device.onReady = { connected.signal() }
            let cached = central.retrieveConnectedPeripherals(withServices: [device.service])
            if let match = cached.first(where: { BluetoothDevice.nameMatches($0.name ?? productName) }) {
                device.connect(match)
            } else {
                central.scanForPeripherals(withServices: [device.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
                device.onScanResult = { peripheral in
                    guard BluetoothDevice.nameMatches(peripheral.name ?? "") else { return }
                    device.central.stopScan()
                    device.connect(peripheral)
                }
            }
        }
        guard connected.wait(timeout: .now() + 12) == .success, device.hasPeripheral else {
            device.close()
            throw HIDDevice.HIDError.notFound
        }
        return device
    }

    private static func nameMatches(_ name: String) -> Bool {
        let value = name.lowercased()
        return (value.contains("basilisk") || value.contains("bsk")) && value.contains("v3") && value.contains("x")
    }

    private var onScanResult: ((CBPeripheral) -> Void)?
    private var onReady: (() -> Void)?

    private func connect(_ peripheral: CBPeripheral) {
        hasPeripheral = true
        self.peripheral = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected { peripheral.discoverServices([service]) }
        else { central.connect(peripheral) }
    }

    func sendWithRetry(_ report: RazerReport) throws -> RazerReport {
        try send(report)
    }

    private func send(_ report: RazerReport) throws -> RazerReport {
        let key: BLEVendorProtocol.Key
        let payload: Data?
        let responseKind: ResponseKind
        switch (report.commandClass, report.commandId) {
        case (0x07, 0x80): key = BLEVendorProtocol.battery; payload = nil; responseKind = .battery
        case (0x07, 0x84): return synthetic(report, argument: 1, value: 0)
        case (0x04, 0x86): key = BLEVendorProtocol.dpiStagesGet; payload = nil; responseKind = .stages
        case (0x04, 0x85): key = BLEVendorProtocol.dpiStagesGet; payload = nil; responseKind = .dpi
        case (0x04, 0x06): key = BLEVendorProtocol.dpiStagesSet; payload = BLEVendorProtocol.dpiStages(from: report, preserving: dpiSnapshot); responseKind = .ack
        case (0x04, 0x05):
            let dpi = (Int(report.arguments[1]) << 8) | Int(report.arguments[2])
            guard let snapshot = try? readDpiSnapshot(), let active = snapshot.values.firstIndex(of: dpi) else {
                throw HIDDevice.HIDError.notSupported
            }
            key = BLEVendorProtocol.dpiStagesSet
            payload = BLEVendorProtocol.dpiStagePayload(values: snapshot.values, active: active,
                stageIDs: snapshot.stageIDs, preservedSlots: snapshot.slots, marker: snapshot.marker)
            responseKind = .ack
        case (0x0F, 0x84):
            key = BLEVendorProtocol.brightnessGet; payload = nil; responseKind = .brightness
        case (0x0F, 0x04):
            key = BLEVendorProtocol.brightnessSet
            payload = Data([report.arguments[2]])
            responseKind = .ack
        case (0x0F, 0x02) where report.arguments[2] == 0x01:
            key = BLEVendorProtocol.colorSet
            payload = Data([0x04, 0, 0, 0, 0, report.arguments[6], report.arguments[7], report.arguments[8]])
            responseKind = .ack
        default:
            throw HIDDevice.HIDError.notSupported
        }

        let data = try exchange(key: key, payload: payload)
        switch responseKind {
        case .ack:
            if report.commandClass == 0x04, report.commandId == 0x05 || report.commandId == 0x06 {
                try BLEVendorProtocol.verifyDpiReadback(for: report, snapshot: readDpiSnapshot())
            }
            return synthetic(report)
        case .battery:
            guard let value = data.first else { throw HIDDevice.HIDError.badResponse }
            let percent = Int(value) <= 100 ? Int(value) : Int((Double(value) * 100 / 255).rounded())
            return synthetic(report, argument: 1, value: UInt8((Double(percent) * 255 / 100).rounded()))
        case .brightness:
            guard let value = data.first else { throw HIDDevice.HIDError.badResponse }
            return synthetic(report, argument: 2, value: value)
        case .stages:
            let snapshot = try BLEVendorProtocol.parseDpiStages(data)
            dpiSnapshot = snapshot
            return BLEVendorProtocol.syntheticStagesReport(snapshot)
        case .dpi:
            let snapshot = try BLEVendorProtocol.parseDpiStages(data)
            dpiSnapshot = snapshot
            var result = synthetic(report)
            let dpi = UInt16(snapshot.values[snapshot.active])
            result.arguments[1] = UInt8(dpi >> 8); result.arguments[2] = UInt8(dpi & 0xFF)
            result.arguments[3] = result.arguments[1]; result.arguments[4] = result.arguments[2]
            return result
        }
    }

    private enum ResponseKind { case ack, battery, brightness, stages, dpi }

    private func synthetic(_ original: RazerReport, argument: Int? = nil, value: UInt8 = 0) -> RazerReport {
        var result = original
        result.status = 0x02
        if let argument { result.arguments[argument] = value }
        return result
    }

    private func readDpiSnapshot() throws -> BLEVendorProtocol.DpiSnapshot {
        let bytes = try exchange(key: BLEVendorProtocol.dpiStagesGet, payload: nil)
        let snapshot = try BLEVendorProtocol.parseDpiStages(bytes)
        dpiSnapshot = snapshot
        return snapshot
    }

    /// Read-only diagnostic used to time the mouse sleep/wake hardware check. This is not
    /// exposed as a user control and never writes or changes the mouse's sleep setting.
    func readSleepTimeoutSeconds() throws -> UInt16 {
        try BLEVendorProtocol.parseSleepTimeout(exchange(key: BLEVendorProtocol.sleepTimeoutGet, payload: nil))
    }

    func readDpiCycleBinding() throws -> BLEVendorProtocol.DPIButtonBinding {
        let payload = try exchange(key: BLEVendorProtocol.buttonBindingGet, payload: nil)
        return try BLEVendorProtocol.parseDpiButtonBinding(payload)
    }

    func setDpiCycleBinding(_ binding: BLEVendorProtocol.DPIButtonBinding) throws {
        _ = try exchange(key: BLEVendorProtocol.buttonBindingSet,
                         payload: BLEVendorProtocol.dpiButtonPayload(for: binding))
        guard try readDpiCycleBinding() == binding else {
            throw HIDDevice.HIDError.badResponse
        }
    }

    private func exchange(key: BLEVendorProtocol.Key, payload: Data?) throws -> Data {
        let id = requestID
        requestID &+= 1
        let semaphore = DispatchSemaphore(value: 0)
        let output = ExchangeResult()
        queue.async {
            guard self.isReady, self.completion == nil, let peripheral = self.peripheral,
                  let write = self.writeCharacteristic else {
                output.set(.failure(HIDDevice.HIDError.notFound)); semaphore.signal(); return
            }
            self.activeRequest = id
            self.notifications = []
            self.writes = payload.map { BLEVendorProtocol.writeFrames(request: id, key: key, payload: $0) }
                ?? [BLEVendorProtocol.readHeader(request: id, key: key)]
            self.completion = { result in output.set(result); semaphore.signal() }
            _ = peripheral
            _ = write
            self.sendNextWrite()
            self.armTimeout(after: 2.0)
        }
        guard semaphore.wait(timeout: .now() + 2.5) == .success else { throw HIDDevice.HIDError.timeout }
        let notifications = try output.get().get()
        return try BLEVendorProtocol.payload(from: notifications, request: id)
    }

    private func sendNextWrite() {
        guard let peripheral, let characteristic = writeCharacteristic else { return }
        guard !writes.isEmpty else { armTimeout(after: 0.14); return }
        let next = writes.removeFirst()
        peripheral.writeValue(next, for: characteristic, type: .withResponse)
    }

    private func armTimeout(after interval: TimeInterval) {
        responseTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.writes.isEmpty else { self?.finish(.success(self?.notifications ?? [])); return }
            self.finish(.failure(HIDDevice.HIDError.timeout))
        }
        responseTimer = item
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    private func finish(_ result: Result<[Data], Error>) {
        guard let completion else { return }
        self.completion = nil
        responseTimer?.cancel()
        responseTimer = nil
        completion(result)
    }

    func close() {
        queue.async {
            self.responseTimer?.cancel()
            self.central?.stopScan()
            self.onScanResult = nil
            self.onReady = nil
            if let peripheral = self.peripheral, peripheral.state == .connected { self.central?.cancelPeripheralConnection(peripheral) }
            self.peripheral = nil
            self.isReady = false
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isPoweredOn = central.state == .poweredOn
        if isPoweredOn {
            readySemaphore.signal()
        } else if central.state == .unauthorized || central.state == .unsupported || central.state == .poweredOff {
            readySemaphore.signal()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        onScanResult?(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.discoverServices([service]) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { finish(.failure(error ?? HIDDevice.HIDError.notFound)) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isReady = false
        finish(.failure(error ?? HIDDevice.HIDError.notFound))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if error != nil { finish(.failure(HIDDevice.HIDError.notFound)); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == self.service }) else { finish(.failure(HIDDevice.HIDError.notFound)); return }
        peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if error != nil { finish(.failure(HIDDevice.HIDError.notFound)); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == writeUUID { writeCharacteristic = characteristic }
            if characteristic.uuid == notifyUUID { notifyCharacteristic = characteristic }
        }
        guard let notifyCharacteristic else { finish(.failure(HIDDevice.HIDError.notFound)); return }
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying, writeCharacteristic != nil else { finish(.failure(error ?? HIDDevice.HIDError.notFound)); return }
        isReady = true
        onReady?(); onReady = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { finish(.failure(error)); return }
        sendNextWrite()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { finish(.failure(error)); return }
        guard characteristic.uuid == notifyUUID, let value = characteristic.value else { return }
        notifications.append(value)
        if writes.isEmpty { armTimeout(after: 0.14) }
    }
}

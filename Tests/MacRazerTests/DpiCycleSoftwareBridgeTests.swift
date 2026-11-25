// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
import CoreGraphics
@testable import MacRazer

final class DpiCycleSoftwareBridgeTests: XCTestCase {
    private func remapper(_ suite: String = #function) -> (ButtonRemapper, UserDefaults) {
        let defaults = UserDefaults(suiteName: "MacRazerTests.\(suite)")!
        defaults.removePersistentDomain(forName: "MacRazerTests.\(suite)")
        return (ButtonRemapper(defaults: defaults), defaults)
    }

    func testSoftwareActionIsPerDeviceAndPersists() {
        let (first, defaults) = remapper()
        first.setActiveDevice("PM2533", deviceID: 0x00BA)
        let action = RemapAction.mediaKey(code: 16, name: "Play / Pause")
        first.saveDpiSoftwareAction(action)

        let second = ButtonRemapper(defaults: defaults)
        second.setActiveDevice("PM2533", deviceID: 0x00BA)
        XCTAssertEqual(second.dpiCycleSoftwareAction, action)
        second.saveDpiSoftwareAction(nil)
        XCTAssertNil(defaults.data(forKey: "dpiCycleSoftwareAction-PM2533"))
    }

    func testBridgeConfirmationAndRestoreGate() {
        let (remapper, _) = remapper()
        remapper.setActiveDevice("PM2533", deviceID: 0x00BA)
        XCTAssertFalse(remapper.shouldRestoreDpiBridge(binding: .dpiCycle, connected: true,
                                                       bluetooth: true, alreadyAttempted: false))
        remapper.saveDpiSoftwareAction(.mediaKey(code: 16, name: "Play / Pause"))
        XCTAssertTrue(remapper.shouldRestoreDpiBridge(binding: .dpiCycle, connected: true,
                                                      bluetooth: true, alreadyAttempted: false))
        // Not read yet (cleared on disconnect): never restore before the fresh read.
        XCTAssertFalse(remapper.shouldRestoreDpiBridge(binding: nil, connected: true,
                                                       bluetooth: true, alreadyAttempted: false))
        remapper.confirmDpiBridge(binding: .softwareBridge)
        XCTAssertTrue(remapper.dpiBridgeBindingConfirmed)
        remapper.confirmDpiBridge(binding: .dpiCycle)
        XCTAssertFalse(remapper.dpiBridgeBindingConfirmed)
    }

    func testReapplyingSavedActionDoesNotCountAsManualChange() {
        let (remapper, _) = remapper()
        remapper.setActiveDevice("PM2533", deviceID: 0x00BA)
        var manualChanges = 0
        remapper.onManualChange = { manualChanges += 1 }
        let action = RemapAction.mediaKey(code: 16, name: "Play / Pause")

        remapper.saveDpiSoftwareAction(action)
        remapper.saveDpiSoftwareAction(action)
        XCTAssertEqual(manualChanges, 1)

        remapper.saveDpiSoftwareAction(.doubleClick)
        XCTAssertEqual(manualChanges, 2)
    }

    func testSoftwareActionMigratesFromPidFallbackToSerialKey() throws {
        let oldKey = "test-pid-\(UUID().uuidString)"
        let newKey = "test-serial-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        let source = "dpiCycleSoftwareAction-\(oldKey)"
        let destination = "dpiCycleSoftwareAction-\(newKey)"
        defer {
            defaults.removeObject(forKey: source)
            defaults.removeObject(forKey: destination)
        }
        let action = RemapAction.mediaKey(code: 16, name: "Play / Pause")
        defaults.set(try JSONEncoder().encode(action), forKey: source)

        MouseController.migratePerDeviceData(from: oldKey, to: newKey)

        XCTAssertNil(defaults.object(forKey: source))
        // Compare the decoded action, not the bytes: JSONEncoder doesn't guarantee key order.
        XCTAssertEqual(try defaults.data(forKey: destination).map { try JSONDecoder().decode(RemapAction.self, from: $0) },
                       action)
    }

    func testKeyboardTapMaskIsOptIn() {
        let mouseOnly = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        let keyboard = mouseOnly | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        XCTAssertFalse(ButtonRemapper.includesKeyboardEvents(mouseOnly))
        XCTAssertTrue(ButtonRemapper.includesKeyboardEvents(keyboard))
    }

    // MARK: The Cobra HyperSpeed

    /// The gate is the capability, not the model: the Cobra over Bluetooth saves a software
    /// action as the Basilisk does, but never through F20 (its private keys carry it), so F20
    /// read from it is never confirmed as the bridge. Over its dongle or cable there is no
    /// Bluetooth control channel, so nothing is saved there.
    func testTheCobraOverBluetoothBindsItsDpiButtonAndItsUSBLinksDont() {
        let (remapper, defaults) = remapper()
        let action = RemapAction.mediaKey(code: 16, name: "Play / Pause")
        remapper.setActiveDevice("COBRA-BT", deviceID: 0x00DC)
        XCTAssertTrue(remapper.supportsDpiButtonBinding)
        XCTAssertTrue(remapper.supportsDpiPrivateKeys)
        XCTAssertFalse(remapper.hasMultiFunctionTrigger, "the Basilisk's note isn't shown for the Cobra")
        remapper.saveDpiSoftwareAction(action)
        XCTAssertEqual(remapper.dpiCycleSoftwareAction, action)
        remapper.confirmDpiBridge(binding: .softwareBridge)
        XCTAssertFalse(remapper.dpiBridgeBindingConfirmed, "F20 is never the Cobra's bridge")

        for pid in [0x00DB, 0x00DA] {
            remapper.setActiveDevice("COBRA-USB-\(pid)", deviceID: pid)
            XCTAssertFalse(remapper.supportsDpiButtonBinding, "PID \(pid)")
            XCTAssertFalse(remapper.supportsDpiPrivateKeys, "PID \(pid)")
            remapper.saveDpiSoftwareAction(action)
            XCTAssertNil(remapper.dpiCycleSoftwareAction, "PID \(pid)")
            XCTAssertNil(defaults.data(forKey: "dpiCycleSoftwareAction-COBRA-USB-\(pid)"), "PID \(pid)")
        }
    }

    /// F20 is never written back to the Cobra, with or without a saved action: its actions go
    /// through driver mode, and its entry keeps DPI Cycle.
    func testTheCobraNeverGetsF20Back() {
        let (remapper, _) = remapper()
        remapper.setActiveDevice("COBRA-BT", deviceID: 0x00DC)
        for action: RemapAction? in [nil, .doubleClick, .gesture(.defaults(for: ButtonRemapper.dpiButton))] {
            remapper.saveDpiSoftwareAction(action)
            for binding: BLEProtocol.DPIButtonBinding? in [nil, .dpiCycle, .leftClick, .softwareBridge] {
                XCTAssertFalse(remapper.shouldRestoreDpiBridge(binding: binding, connected: true,
                                                               bluetooth: true, alreadyAttempted: false),
                               "\(action?.label ?? "no action"), \(binding?.label ?? "not read")")
            }
        }
    }

    // MARK: Reading before writing

    /// A read of entry 0x60 in the function-table layout the Cobra answers 0x04 and 0x05 in:
    /// `60, flag`, then the current and factory blocks interleaved byte by byte.
    private func entry(current: [UInt8], factory: [UInt8] = BLEProtocol.dpiCycleBlock, flag: UInt8 = 0) -> Data {
        Data([0x60, flag] + zip(current, factory).flatMap { [$0, $1] })
    }

    /// A mouse for `BluetoothDevice.writeDpiCycleBinding`: answers reads from `reads` in
    /// order (the last one again once they run out) and records every write. On profile 1,
    /// unless `activeSlot` says otherwise (`readActiveSlot`'s answer, 1 when it has none).
    private final class Entry {
        var reads: [Result<Data, Error>]
        var readCount = 0
        var writes: [[UInt8]] = []
        var refusesWrites = false
        var activeSlot: UInt8 = 0x01
        init(_ reads: [Result<Data, Error>]) { self.reads = reads }

        func read() throws -> Data {
            readCount += 1
            let next = reads.count > 1 ? reads.removeFirst() : reads[0]
            return try next.get()
        }

        func write(_ payload: [UInt8]) throws {
            writes.append(payload)
            if refusesWrites { throw HIDDevice.HIDError.commandFailed }
        }
    }

    private func write(_ binding: BLEProtocol.DPIButtonBinding, to mouse: Entry) throws {
        try BluetoothDevice.writeDpiCycleBinding(binding, activeSlot: { mouse.activeSlot }, read: mouse.read,
                                                 write: mouse.write)
    }

    /// The first write on a mouse where 0x60 is unconfirmed must not land anywhere it
    /// shouldn't: a read that fails, or doesn't parse, writes nothing.
    func testNothingIsWrittenWhenTheReadBeforeItFailsOrDoesntParse() {
        let cases: [(String, Result<Data, Error>, Error)] = [
            ("no answer", .failure(HIDDevice.HIDError.timeout), HIDDevice.HIDError.timeout),
            ("refused", .failure(HIDDevice.HIDError.notSupported), HIDDevice.HIDError.notSupported),
            ("a macro", .success(entry(current: [0x05, 0x01, 0x07, 0, 0, 0, 0])),
             BLEProtocol.DPIButtonEntryError.unrecognized),
            ("nothing", .success(entry(current: [0, 0, 0, 0, 0, 0, 0])), BLEProtocol.DPIButtonEntryError.unrecognized),
            ("another entry's reply", .success(Data([0x04, 0, 1, 1, 1, 1, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0])),
             BLEProtocol.DPIButtonEntryError.unrecognized),
            ("too short", .success(Data([0x60, 0x00, 0x06])), BLEProtocol.DPIButtonEntryError.unrecognized),
            ("a factory function that isn't DPI Cycle",
             .success(entry(current: [0x01, 0x01, 0x04, 0, 0, 0, 0], factory: [0x01, 0x01, 0x04, 0, 0, 0, 0])),
             BLEProtocol.DPIButtonEntryError.notTheDpiButton),
        ]
        for (name, read, expected) in cases {
            let mouse = Entry([read])
            XCTAssertThrowsError(try write(.softwareBridge, to: mouse), name) { error in
                XCTAssertEqual(String(describing: error), String(describing: expected), name)
            }
            XCTAssertEqual(mouse.writes, [], "\(name): nothing written")
        }
    }

    /// A read naming DPI Cycle as the factory function, or a binding this app wrote, lets the
    /// write go ahead; it is sent once and read back.
    func testAKnownEntryIsWrittenOnceAndReadBack() throws {
        let f20 = Array(BLEProtocol.dpiButtonPayload(for: .softwareBridge).dropFirst(3))
        let mouse = Entry([.success(entry(current: BLEProtocol.dpiCycleBlock)), .success(entry(current: f20))])
        try write(.softwareBridge, to: mouse)
        XCTAssertEqual(mouse.writes, [Array(BLEProtocol.dpiButtonPayload(for: .softwareBridge))])

        // Over a binding of its own, in the short layout, which has no factory block.
        let back = Entry([.success(BLEProtocol.dpiButtonPayload(for: .back)),
                          .success(BLEProtocol.dpiButtonPayload(for: .softwareBridge))])
        try write(.softwareBridge, to: back)
        XCTAssertEqual(back.writes.count, 1)
    }

    /// With the HyperShift flag the second block is a layer, not the factory function, so
    /// only what the button does now decides.
    func testAHyperShiftLayerIsNotTakenForTheFactoryFunction() throws {
        let shifted = entry(current: BLEProtocol.dpiCycleBlock, factory: [0x02, 0x02, 0x00, 0x04, 0, 0, 0], flag: 0x01)
        XCTAssertEqual(try BLEProtocol.parseDpiButtonBinding(shifted), .dpiCycle)
    }

    /// The write path keeps its read-back: a mismatch throws, and nothing is written again.
    func testAReadBackThatDiffersThrowsAndIsNotRetried() {
        let mouse = Entry([.success(entry(current: BLEProtocol.dpiCycleBlock))])
        XCTAssertThrowsError(try write(.softwareBridge, to: mouse)) { error in
            XCTAssertEqual(error as? BLEProtocol.DPIButtonWriteError, .notReadBack)
        }
        XCTAssertEqual(mouse.writes.count, 1)

        let refusing = Entry([.success(entry(current: BLEProtocol.dpiCycleBlock))])
        refusing.refusesWrites = true
        XCTAssertThrowsError(try write(.softwareBridge, to: refusing)) { error in
            XCTAssertEqual(error as? BLEProtocol.DPIButtonWriteError, .notTaken)
        }
    }

    /// The write goes to profile 1 and the reads around it see the profile in use. On a mouse
    /// using another onboard profile, the read before would check that profile's entry and the
    /// write change profile 1's, which nothing read (a macro Synapse saved there would be
    /// lost), the read-back would never match, and the page would say it "may not have
    /// changed" while profile 1 had. So nothing is read or written there, whatever the
    /// binding, the automatic restore of F20 included.
    func testNothingIsWrittenWhileTheMouseIsOnAnotherProfile() {
        let f20 = Array(BLEProtocol.dpiButtonPayload(for: .softwareBridge).dropFirst(3))
        for slot: UInt8 in 2...5 {
            for binding in [BLEProtocol.DPIButtonBinding.softwareBridge, .dpiCycle, .back] {
                let mouse = Entry([.success(entry(current: BLEProtocol.dpiCycleBlock)), .success(entry(current: f20))])
                mouse.activeSlot = slot
                XCTAssertThrowsError(try write(binding, to: mouse), "profile \(slot), \(binding.label)") { error in
                    XCTAssertEqual(error as? BLEProtocol.DPIButtonEntryError, .otherProfileInUse(slot))
                }
                XCTAssertEqual(mouse.writes, [], "profile \(slot), \(binding.label): nothing written")
                XCTAssertEqual(mouse.readCount, 0, "profile \(slot), \(binding.label): nor read")
            }
        }
        XCTAssertEqual(BLEProtocol.Key.dpiButtonSet.bytes[2], 0x01, "the write's slot")
        XCTAssertEqual(BLEProtocol.dpiButtonPayload(for: .softwareBridge).first, 0x01, "and its payload's")
        XCTAssertEqual(BLEProtocol.Key.dpiButtonGet.bytes[2], 0x00, "the reads see the profile in use")
    }

    /// On profile 1, or on a mouse that doesn't say which profile it's using (`readActiveSlot`
    /// answers 1 then), the write goes ahead as before.
    func testOnProfileOneTheWriteGoesAhead() throws {
        let f20 = Array(BLEProtocol.dpiButtonPayload(for: .softwareBridge).dropFirst(3))
        let mouse = Entry([.success(entry(current: BLEProtocol.dpiCycleBlock)), .success(entry(current: f20))])
        mouse.activeSlot = 0x01
        try write(.softwareBridge, to: mouse)
        XCTAssertEqual(mouse.writes.count, 1)
        XCTAssertEqual(mouse.readCount, 2, "the read before and the read back")
    }

    /// DPI Cycle (default) writes exactly the factory block back, from any binding.
    func testDpiCycleDefaultWritesTheFactoryBlock() throws {
        XCTAssertEqual(Array(BLEProtocol.dpiButtonPayload(for: .dpiCycle)), [0x01, 0x60, 0x00] + BLEProtocol.dpiCycleBlock)
        XCTAssertEqual(BLEProtocol.dpiCycleBlock, [0x06, 0x01, 0x06, 0, 0, 0, 0])
        let f20 = Array(BLEProtocol.dpiButtonPayload(for: .softwareBridge).dropFirst(3))
        let mouse = Entry([.success(entry(current: f20)), .success(entry(current: BLEProtocol.dpiCycleBlock))])
        try write(.dpiCycle, to: mouse)
        XCTAssertEqual(mouse.writes, [[0x01, 0x60, 0x00, 0x06, 0x01, 0x06, 0, 0, 0, 0]])
        XCTAssertEqual(ButtonRemapper.dpiButtonAssignment(for: .passthrough)?.binding, .dpiCycle,
                       "the menu's DPI Cycle (default) is its None")
        XCTAssertNil(ButtonRemapper.dpiButtonAssignment(for: .passthrough)?.softwareAction,
                     "and clears the saved action, needing no event tap")
    }

    /// The DPI button's entry and the side buttons' are separate: neither feature reads the
    /// other's, so F20 on 0x60 is never offered as a side-button remap to reset, and a side
    /// button's reply is never read as the DPI button.
    func testTheDpiButtonAndSideButtonResetNeverShareAnEntry() {
        XCTAssertFalse(SideButtonReset.ids.contains(0x60))
        XCTAssertEqual(BLEProtocol.Key.dpiButtonGet.bytes[3], 0x60)
        XCTAssertEqual(BLEProtocol.Key.dpiButtonSet.bytes[3], 0x60)
        for binding in BLEProtocol.DPIButtonBinding.allCases + [.softwareBridge] {
            XCTAssertEqual(BLEProtocol.dpiButtonPayload(for: binding)[1], 0x60, binding.label)
        }
        let f20 = Array(BLEProtocol.dpiButtonPayload(for: .softwareBridge).dropFirst(3))
        XCTAssertNil(SideButtonReset.remap(id: 0x60, payload: entry(current: f20)))
        let sideButton = Data([0x04, 0, 2, 1, 2, 1, 1, 4, 25, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try BLEProtocol.parseDpiButtonBinding(sideButton))
    }

    // MARK: What the page says

    /// The section's errors are plain sentences, never an error's debug text, and each read
    /// error says nothing was changed.
    func testTheErrorsArePlainSentences() {
        let errors: [Error] = [
            BLEProtocol.DPIButtonEntryError.unrecognized, BLEProtocol.DPIButtonEntryError.notTheDpiButton,
            BLEProtocol.DPIButtonEntryError.otherProfileInUse(3),
            BLEProtocol.DPIButtonWriteError.notTaken, BLEProtocol.DPIButtonWriteError.notReadBack,
            HIDDevice.HIDError.timeout, HIDDevice.HIDError.notSupported, HIDDevice.HIDError.badResponse,
        ]
        for error in errors {
            let text = MouseController.dpiButtonErrorText(error)
            XCTAssertTrue(text.hasSuffix("."), text)
            XCTAssertFalse(text.contains("—"), text)
            XCTAssertFalse(text.contains("HIDError") || text.contains("0x"), text)
        }
        for error: Error in [BLEProtocol.DPIButtonEntryError.unrecognized, BLEProtocol.DPIButtonEntryError.notTheDpiButton,
                             BLEProtocol.DPIButtonEntryError.otherProfileInUse(3), HIDDevice.HIDError.notSupported] {
            XCTAssertTrue(MouseController.dpiButtonErrorText(error).contains("won't change it"), "\(error)")
        }
        XCTAssertTrue(MouseController.dpiButtonErrorText(BLEProtocol.DPIButtonEntryError.otherProfileInUse(3))
                        .contains("profile 3"), "names the profile the mouse is on")
    }
}

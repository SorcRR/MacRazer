// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The onboard profile slots of the Basilisk V4 Pro, learned from the mouse's own replies
/// over the dongle (no OpenRazer driver has them).
///
/// The mouse holds up to 5 profiles, numbered 1-5. Slot 1 always exists and is the one
/// every earlier MacRazer wrote to. The first argument of each settings command (OpenRazer's
/// VARSTORE byte, 0x01) is really the slot number: a write to the active slot changes the
/// mouse at once, a write to another slot only changes what that slot holds. So everything
/// the app sends is pointed at the active slot (`OnboardSlotTransport`), and a profile whose
/// slot is active keeps working with MacRazer quit.
///
///   0x05/0x81 -> [max, ids...]   the slots that exist (factory: [5, 1])
///   0x05/0x84 -> [id]            the active slot
///   0x05/0x02 [id]               create a slot; it starts with the settings last stored in it
///   0x05/0x03 [id]               remove a slot (never slot 1)
///   0x05/0x04 [id]               make a slot active; refused for a slot that doesn't exist
enum OnboardSlots {
    static let first: UInt8 = 1
    static let maxSlots = 5

    static func listSlots() -> RazerReport { RazerReport(commandClass: 0x05, commandId: 0x81, dataSize: 0x0A) }
    static func getActive() -> RazerReport { RazerReport(commandClass: 0x05, commandId: 0x84, dataSize: 0x0A) }
    static func create(_ slot: UInt8) -> RazerReport { command(0x02, slot) }
    static func remove(_ slot: UInt8) -> RazerReport { command(0x03, slot) }
    static func activate(_ slot: UInt8) -> RazerReport { command(0x04, slot) }

    private static func command(_ id: UInt8, _ slot: UInt8) -> RazerReport {
        var r = RazerReport(commandClass: 0x05, commandId: id, dataSize: 0x01)
        r.arguments[0] = slot
        return r
    }

    /// The slots that exist, from a `listSlots` reply. Nil when the reply makes no sense.
    static func parseSlots(_ resp: RazerReport) -> Set<UInt8>? {
        let size = Int(resp.dataSize)
        guard size >= 2, size <= resp.arguments.count else { return nil }
        let ids = Set(resp.arguments[1..<size].filter(isSlot))
        return ids.contains(first) ? ids : nil
    }

    static func parseActive(_ resp: RazerReport) -> UInt8? {
        isSlot(resp.arguments[0]) ? resp.arguments[0] : nil
    }

    static func isSlot(_ value: UInt8) -> Bool { value >= first && Int(value) <= maxSlots }

    /// Where a profile goes when it is applied: its own slot if it has one, else the active
    /// slot when no other profile holds it (so a mouse's first profile stays on the slot it
    /// already uses), else the lowest slot nobody holds. Nil when all five are taken.
    static func slot(for profile: UUID, assigned: [UUID: Int], active: Int) -> Int? {
        if let own = assigned[profile] { return own }
        let taken = Set(assigned.values)
        if !taken.contains(active) { return active }
        return (1...maxSlots).first { !taken.contains($0) }
    }

    /// The settings commands whose first argument is the slot, by class and id.
    private static let slotted: Set<UInt16> = [
        0x0405, 0x0485, 0x0406, 0x0486, // DPI, DPI stages
        0x020C, 0x028C,                 // button functions
        0x0214, 0x0294, 0x0217, 0x0297, // scroll mode, Smart-Reel
        0x0230, 0x02B0,                 // wheel mode
        0x0F02, 0x0F82, 0x0F04, 0x0F84, // lighting effect, brightness
    ]

    /// `report` pointed at `slot` when it is a settings command addressed to slot 1.
    static func retarget(_ report: RazerReport, to slot: UInt8) -> RazerReport {
        guard slot != first, report.arguments[0] == first,
              slotted.contains(UInt16(report.commandClass) << 8 | UInt16(report.commandId)) else { return report }
        var r = report
        r.arguments[0] = slot
        return r
    }

    /// The slot a new profile goes in: the lowest that doesn't exist yet. Nil when all five do.
    static func nextFreeSlot(existing: Set<Int>) -> Int? {
        (Int(first) + 1...maxSlots).first { !existing.contains($0) }
    }

    /// What a slot holds from the factory, as the reports that write it (addressed to slot 1;
    /// `retarget` points them elsewhere). The bytes are the Basilisk V4 Pro's untouched slots
    /// 3-5, read on 2026-10-22, written raw: the stage table repeats each stage's DPI where
    /// `RazerCommands.setDPIStages` writes zeros, and the factory spectrum carries a colour
    /// that `ZonedLighting.body(.spectrum)` doesn't. The button table is put back separately
    /// (`OnboardButtons.layout`). Wheel mode reads FF (never set) and is left out. Over
    /// Bluetooth the stage table already sets the DPI, which has no command of its own there,
    /// and Smart-Reel has none at all; that link also numbers the active stage from 0.
    static func factorySettings(pid: Int) -> [RazerReport] {
        guard let table = RazerDevices.buttonTable(pid: pid) else { return [] }
        let bluetooth = RazerDevices.connection(pid: pid) == .bluetooth
        // Stage 3 of 5 (1600 DPI), in this link's numbering.
        let activeStage: UInt8 = RazerDevices.dpiStagesCountFromOne(pid: pid) ? 0x03 : 0x02
        switch table {
        case .basiliskV4Pro:
            func raw(_ commandClass: UInt8, _ id: UInt8, _ size: UInt8, _ args: [UInt8]) -> RazerReport {
                var r = RazerReport(commandClass: commandClass, commandId: id, dataSize: size)
                r.arguments[0] = first
                for (i, byte) in args.enumerated() { r.arguments[1 + i] = byte }
                return r
            }
            // 400, 800, 1600, 3200, 6400.
            let stages: [UInt8] = [activeStage, 0x05] + [(1, 400), (2, 800), (3, 1600), (4, 3200), (5, 6400)].flatMap { id, dpi -> [UInt8] in
                let hi = UInt8(dpi >> 8), lo = UInt8(dpi & 0xFF)
                return [UInt8(id), hi, lo, hi, lo, hi, lo]
            }
            let spectrum: [UInt8] = [0x03, 0x01, 0x28, 0x01, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00]
            let lighting = [LightingZone.scrollWheel, .logo, .underglow].flatMap { zone in
                [raw(0x0F, 0x02, 0x0C, [zone.rawValue] + spectrum), RazerCommands.setBrightness(0x55, led: zone.rawValue)]
            }
            if bluetooth { return [raw(0x04, 0x06, 0x26, stages)] + lighting }
            return [raw(0x04, 0x06, 0x26, stages), RazerCommands.setDPI(x: 1600, y: 1600)] + lighting
                + [RazerCommands.setScrollSmartReel(false)]
        }
    }

    /// Ownership records (`OnboardOwnership`) are kept per slot. Slot 1 keeps the plain
    /// serial, which is what earlier builds recorded it under.
    static func ownershipKey(serial: String, slot: UInt8) -> String {
        slot == first ? serial : serial + "#slot\(slot)"
    }
}

/// The link of a mouse with onboard slots, with every settings command pointed at the
/// active slot. Owned by `MouseController` and used on its `io` queue only.
///
/// Over Bluetooth the same profile commands are translated by `BLEProtocol` (class 0x03 there),
/// and the slot goes in the third byte of each settings key, which `BluetoothDevice` fills in.
final class OnboardSlotTransport: RazerTransport, ButtonFunctionTable {
    let base: any RazerTransport & ButtonFunctionTable
    /// The slot settings commands go to. Set by `MouseController` when it reads or changes
    /// the active slot.
    var slot: UInt8 = OnboardSlots.first {
        didSet { (base as? BluetoothDevice)?.slot = slot }
    }

    init(_ base: any RazerTransport & ButtonFunctionTable) { self.base = base }

    var productID: Int { base.productID }
    var productName: String { base.productName }
    var locationID: Int { base.locationID }
    var isBluetooth: Bool { base.isBluetooth }
    func close() { base.close() }

    func sendWithRetry(_ report: RazerReport) throws -> RazerReport {
        try base.sendWithRetry(OnboardSlots.retarget(report, to: slot))
    }

    // The same table commands as `HIDDevice`'s, sent through `sendWithRetry` above. Bluetooth
    // has its own table commands, already pointed at the slot.
    func readButtonBlock(_ id: UInt8) throws -> [UInt8] {
        if base.isBluetooth { return try base.readButtonBlock(id) }
        guard let block = RazerCommands.parseButtonFunction(try sendWithRetry(RazerCommands.getButtonFunction(id)), id: id)
        else { throw HIDDevice.HIDError.badResponse }
        return block
    }

    func writeButtonBlock(_ id: UInt8, block: [UInt8]) throws {
        if base.isBluetooth { return try base.writeButtonBlock(id, block: block) }
        _ = try sendWithRetry(RazerCommands.setButtonFunction(id, block: block))
        guard try readButtonBlock(id) == block else { throw HIDDevice.HIDError.badResponse }
    }

    func readShiftedBlock(_ id: UInt8) throws -> [UInt8]? {
        if base.isBluetooth { return try base.readShiftedBlock(id) }
        let resp = try sendWithRetry(RazerCommands.getButtonFunction(id, layer: 0x01))
        switch RazerCommands.parseShiftedButtonFunction(resp, id: id) {
        case .set(let block): return block
        case .unset: return nil
        case nil: throw HIDDevice.HIDError.badResponse
        }
    }

    func writeShiftedBlock(_ id: UInt8, block: [UInt8]) throws {
        if base.isBluetooth { return try base.writeShiftedBlock(id, block: block) }
        _ = try sendWithRetry(RazerCommands.setButtonFunction(id, block: block, layer: 0x01))
        guard try readShiftedBlock(id) == block else { throw HIDDevice.HIDError.badResponse }
    }
}

extension RazerTransport {
    /// The Bluetooth link under this one, for the commands only Bluetooth has.
    var bluetoothDevice: BluetoothDevice? {
        (self as? BluetoothDevice) ?? ((self as? OnboardSlotTransport)?.base as? BluetoothDevice)
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Side buttons that the mouse itself was told to send something else, and putting them back.
///
/// Razer Synapse saves remaps in the mouse's own function table. A side button set there to
/// send Ctrl+V sends Ctrl+V on every computer, and Configure Buttons never sees it as a button
/// to remap. A Cobra HyperSpeed over Bluetooth (0x00DC, a Report an Issue on 0.9.0) answered
/// entries 0x04 and 0x05 with Ctrl+V and Ctrl+C as the current block and mouse buttons 4 and 5
/// as the factory one, in the read layout the Basilisk V4 Pro's work measured
/// (`BLEProtocol.ButtonFunction`, #55).
///
/// Only models with `RazerDeviceInfo.detectsOnboardSideButtonRemaps` are checked. A mouse
/// whose remaps MacRazer writes to the table itself (#55) must not have them offered for reset.
enum SideButtonReset {
    /// The function table entries of the side buttons, which are also their HID button
    /// numbers (4 back, 5 forward).
    static let ids: [UInt8] = [0x04, 0x05]

    /// A side button whose entry differs from its factory function.
    struct Remap: Equatable, Sendable {
        let id: UInt8
        let current: [UInt8]
        /// The block the mouse reports as the factory one, which a reset writes back.
        let factory: [UInt8]
    }

    /// Why a reset stopped.
    enum ResetError: Error, Equatable {
        /// The remap is in one profile slot only, and not the one 03/82 named, so which slot is
        /// in use is unclear. Nothing was written.
        case slotUnconfirmed
        /// No profile slot read back the remap the in-use read showed. Nothing was written.
        case notInAnySlot
        /// The write went through but the mouse didn't read back the factory block.
        case notReadBack
        /// Some profile slots took the write and a later one didn't.
        case partlyWritten
    }

    /// The profile slots a reset reads. 03/82 answers 1 to 5.
    static let slots: ClosedRange<UInt8> = 1...5

    /// Whether a read of a profile slot holds exactly the same current block as `remap`,
    /// which was read from the slot in use. A reply that doesn't parse is no.
    static func slotHolds(_ remap: Remap, slotPayload: Data) -> Bool {
        (try? BLEProtocol.parseButtonFunction(id: remap.id, slotPayload))?.current == remap.current
    }

    /// The profile slots a reset of `remap` writes, from reads of each slot (a slot the mouse
    /// refused to read is left out). 03/82 was only measured on the Basilisk V4 Pro, and
    /// Synapse often saves one remap to every profile, so the slot it names holding the remap
    /// proves little on its own.
    ///
    /// - The remap in more than one slot: every slot holding it, since the one in use is among
    ///   them and they all hold the same leftover remap.
    /// - In the named slot only: that slot.
    /// - In another slot only: `slotUnconfirmed`. In none: `notInAnySlot`.
    ///
    /// A slot whose read differs from the remap in any byte is never written.
    static func slotsToReset(_ remap: Remap, activeSlot: UInt8, slotPayloads: [UInt8: Data]) throws -> [UInt8] {
        let holders = slotPayloads.filter { slotHolds(remap, slotPayload: $0.value) }.keys.sorted()
        if holders.isEmpty { throw ResetError.notInAnySlot }
        if holders.count == 1 && holders != [activeSlot] { throw ResetError.slotUnconfirmed }
        return holders
    }

    /// The notice's line after a reset that went through, by how many profile slots it wrote.
    static func doneText(profiles: Int) -> String {
        profiles > 1 ? "Side buttons reset on all \(profiles) profiles that had the remap." : "Side buttons reset."
    }

    /// The notice's line for a failed reset, in plain words.
    static func failureText(_ error: Error) -> String {
        switch error {
        case ResetError.slotUnconfirmed:
            return "MacRazer couldn't confirm which profile the mouse is using, so it changed nothing."
        case ResetError.notInAnySlot:
            return "MacRazer couldn't find the remap in the mouse's profiles, so it changed nothing."
        case ResetError.partlyWritten:
            return "The mouse took the reset on some profiles but not all. Try again."
        case ResetError.notReadBack:
            return "The mouse didn't read the button back as reset, so it may not have worked."
        case HIDDevice.HIDError.timeout, HIDDevice.HIDError.notFound:
            return "The mouse stopped answering. Check that it's on and try again."
        default:
            return "The mouse didn't take the reset. Try again, or reset the buttons in Razer Synapse."
        }
    }

    /// The block a mouse button is, by its HID number.
    static func mouseBlock(_ hidButton: UInt8) -> [UInt8] { [0x01, 0x01, hidButton, 0, 0, 0, 0] }

    /// The remap in a read of entry `id`, or nil when there is nothing to put back. Fails
    /// closed: the reply must echo the id, the flag must be 0 (with 01 the second block is a
    /// HyperShift layer, not the factory function), and the factory block must be exactly the
    /// side button itself. Anything else, a macro included, still counts as a remap.
    static func remap(id: UInt8, payload: Data) -> Remap? {
        let bytes = Array(payload)
        guard ids.contains(id), bytes.count >= 16, bytes[1] == 0x00,
              let function = try? BLEProtocol.parseButtonFunction(id: id, payload),
              function.factory == mouseBlock(id), function.current != function.factory else { return nil }
        return Remap(id: id, current: function.current, factory: function.factory)
    }

    /// The button's name on the page.
    static func name(_ id: UInt8) -> String { id == 0x04 ? "Back" : "Forward" }

    /// What the button sends now, in words, or nil when MacRazer can't say.
    static func describe(_ block: [UInt8]) -> String? {
        guard block.count == 7 else { return nil }
        switch (block[0], block[1]) {
        case (0x00, _):
            return "nothing"
        case (0x01, 0x01):
            return BLEProtocol.DPIButtonBinding.allCases.first { $0.buttonID == block[2] }?.label
        case (0x02, 0x02) where block[3] != 0:
            // A lone modifier (usage 0) has no key to name, so it gets the generic text.
            return BLEProtocol.shortcutLabel(hidUsage: block[3], modifiers: block[2])
        default:
            return nil
        }
    }

    /// The notice's text, for one or both buttons.
    static func noticeText(_ remaps: [Remap]) -> String {
        let parts = remaps.map { remap -> String in
            if let what = describe(remap.current) { return "\(name(remap.id)) sends \(what)" }
            return "\(name(remap.id)) does something else"
        }
        let list = ListFormatter.localizedString(byJoining: parts)
        let pronoun = remaps.count == 1 ? "it's" : "they're"
        return "Your mouse has its side buttons saved to other functions, probably by Razer Synapse: "
            + "\(list). Configure Buttons can't remap them as Back and Forward until \(pronoun) reset. "
            + "Resetting puts them back in the mouse itself, which removes what was saved there."
    }
}

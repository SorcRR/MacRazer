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
        /// The slot the write would go to doesn't hold the remap the in-use read showed, so it
        /// may not be the slot in use. Nothing was written.
        case slotUnconfirmed
        /// The write went through but the mouse didn't read back the factory block.
        case notReadBack
    }

    /// Whether a read of the slot about to be written holds the same current block as `remap`,
    /// which was read from the slot in use. A reply that doesn't parse is no.
    static func slotHolds(_ remap: Remap, slotPayload: Data) -> Bool {
        (try? BLEProtocol.parseButtonFunction(id: remap.id, slotPayload))?.current == remap.current
    }

    /// The notice's line for a failed reset, in plain words.
    static func failureText(_ error: Error) -> String {
        switch error {
        case ResetError.slotUnconfirmed:
            return "MacRazer couldn't confirm which profile the mouse is using, so it changed nothing."
        case ResetError.notReadBack:
            return "The mouse didn't read back Back and Forward, so the reset may not have worked."
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

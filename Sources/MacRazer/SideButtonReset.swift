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
            let names: [UInt8: String] = [1: "Left Click", 2: "Right Click", 3: "Middle Click",
                                          4: "Back", 5: "Forward", 9: "Scroll Up", 10: "Scroll Down"]
            return names[block[2]]
        case (0x02, 0x02) where block[3] != 0 || block[2] != 0:
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
        let pronoun = remaps.count == 1 ? "it isn't a mouse button" : "they aren't mouse buttons"
        return "Your mouse has its side buttons saved to other functions, probably by Razer Synapse: "
            + "\(list). MacRazer can't remap them while \(pronoun). "
            + "Resetting puts them back to Back and Forward in the mouse itself, which removes what was saved there."
    }
}

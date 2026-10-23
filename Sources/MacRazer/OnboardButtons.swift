// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import CoreGraphics

/// Remaps saved in the mouse itself, the way Synapse saves them: every control has an entry
/// in the mouse's function table, and what is written there is what the mouse sends, on any
/// connection and with MacRazer closed.
///
/// The table, its entry ids and the block layout were read from the Basilisk V4 Pro over the
/// dongle (`RazerCommands.getButtonFunction`) and over Bluetooth
/// (`BLEProtocol.Key.buttonFunctionGet`), and each id was confirmed by writing a test key to
/// it and pressing the button (findings.md, 2026-10-19). The media-key block was read from a
/// Basilisk Mobile that Synapse had configured.
///
/// A block is seven bytes: a function type, the length of its data, then the data.
enum OnboardButtons {
    /// One remappable control: the id the remap table keys it by (a CGEvent button number or a
    /// `HardwareButton`), its entry in the mouse's table, and what the entry holds from the
    /// factory.
    struct Control: Equatable, Sendable {
        let button: Int
        let tableID: UInt8
        let factory: [UInt8]
    }

    /// The controls of a mouse whose table is known, or nil. Left click is left out on
    /// purpose: a mistake there would leave the mouse unable to click. Right click is in, as
    /// in Synapse (entry 0x02, factory 01 01 02). Scroll up and down
    /// (0x09, 0x0A) are in: on the factory function each notch is a wheel step, read from
    /// the mouse (01 01 09, 01 01 0A). So are the side trigger (entry 0x39, HyperShift from the
    /// factory) and the wheel-mode button (entry 0x6A), both of which Synapse remaps too: a key
    /// written to each fired from that button alone (2026-10-22). Their factory blocks are the
    /// two functions the Basilisk V3's table documents as HyperShift switching (0C) and wheel
    /// mode switching (12), github.com/geezmolycos/razerqdhid docs/cmd_button-en.md.
    static func layout(pid: Int) -> [Control]? {
        RazerDevices.buttonTable(pid: pid).map(layout)
    }

    /// The function tables MacRazer knows, named by the mouse they were read from. A registry
    /// row points at one (`RazerDeviceInfo.buttonTable`), so mice that share a table share it.
    enum Table: Equatable, Sendable {
        /// Basilisk V4 Pro: the same table on the cable, the dongle and Bluetooth.
        case basiliskV4Pro
    }

    static func layout(_ table: Table) -> [Control] {
        switch table {
        case .basiliskV4Pro:
            return [
                Control(button: 1, tableID: 0x02, factory: mouseBlock(2)),
                Control(button: 2, tableID: 0x03, factory: mouseBlock(3)),
                Control(button: HardwareButton.scrollUp.rawValue, tableID: 0x09, factory: mouseBlock(9)),
                Control(button: HardwareButton.scrollDown.rawValue, tableID: 0x0A, factory: mouseBlock(10)),
                Control(button: 3, tableID: 0x04, factory: mouseBlock(4)),
                Control(button: 4, tableID: 0x05, factory: mouseBlock(5)),
                Control(button: HardwareButton.dpiCycle.rawValue, tableID: 0x60, factory: [0x06, 0x01, 0x06, 0, 0, 0, 0]),
                Control(button: HardwareButton.sideFront.rawValue, tableID: 0x80, factory: disabledBlock),
                Control(button: HardwareButton.leftClickSide.rawValue, tableID: 0x0E, factory: [0x07, 0x01, 0x04, 0, 0, 0, 0]),
                Control(button: HardwareButton.tiltLeft.rawValue, tableID: 0x34, factory: [0x0E, 0x01, 0x68, 0x00, 0x14, 0, 0]),
                Control(button: HardwareButton.tiltRight.rawValue, tableID: 0x35, factory: [0x0E, 0x01, 0x69, 0x00, 0x14, 0, 0]),
                Control(button: HardwareButton.sideTrigger.rawValue, tableID: 0x39, factory: [0x0C, 0x01, 0x39, 0, 0, 0, 0]),
                Control(button: HardwareButton.wheelMode.rawValue, tableID: 0x6A, factory: [0x12, 0x01, 0x01, 0, 0, 0, 0]),
            ]
        }
    }

    /// What a control does from the factory, in the remap menu's words, for a row with no
    /// remap: Synapse's default map (Left Side cycles profiles up, Side Front is off, the side
    /// trigger is HyperShift).
    static func factoryLabel(_ control: Control) -> String {
        switch (control.factory[0], control.factory[2]) {
        case (0x00, _): return "Disabled"
        case (0x01, 1): return "Left Click"
        case (0x01, 2): return "Right Click"
        case (0x01, 3): return "Middle Click"
        case (0x01, 4): return "Back"
        case (0x01, 5): return "Forward"
        case (0x01, 9): return "Scroll Up"
        case (0x01, 10): return "Scroll Down"
        case (0x06, 0x06): return "DPI Cycle Up"
        case (0x07, 0x04): return "Cycle Up Profile"
        case (0x07, 0x05): return "Cycle Down Profile"
        case (0x0E, 0x68): return "Scroll Left"
        case (0x0E, 0x69): return "Scroll Right"
        case (0x0C, _): return "HyperShift"
        case (0x12, _): return "Cycle Scroll Mode"
        default: return "Default"
        }
    }

    /// Whether a control is the HyperShift clutch on its factory function (the side trigger),
    /// so it needs no HyperShift remap to be one.
    static func isHyperShiftOnFactory(_ control: Control) -> Bool {
        control.factory.first == 0x0C
    }

    /// The order the remap window lists a mouse's controls in, top to bottom, as they sit on
    /// the mouse. Nil for a mouse without one.
    static func rowOrder(pid: Int) -> [Int]? {
        guard layout(pid: pid) != nil else { return nil }
        return [HardwareButton.leftClickSide.rawValue,
                1, 2, HardwareButton.scrollUp.rawValue, HardwareButton.scrollDown.rawValue, HardwareButton.tiltLeft.rawValue, HardwareButton.tiltRight.rawValue,
                HardwareButton.wheelMode.rawValue, HardwareButton.dpiCycle.rawValue,
                HardwareButton.sideTrigger.rawValue, HardwareButton.sideFront.rawValue,
                4, 3]
    }

    /// Whether MacRazer sees the control's presses while it holds its factory function: only
    /// the ones that are a mouse button then. Actions only MacRazer can do (Double Click,
    /// HyperShift) work on those alone.
    static func appSees(_ control: Control) -> Bool {
        // Mouse buttons 3-5 only: the tap takes the extra buttons' events, not left or right
        // click, and scroll up and down (01 01 09 / 0A) arrive as wheel steps.
        control.factory.first == 0x01 && (3...5).contains(control.factory[2])
    }

    // MARK: Blocks

    static let disabledBlock: [UInt8] = [0x00, 0x01, 0x00, 0, 0, 0, 0]

    /// A mouse button by its HID number (1 left, 2 right, 3 middle, 4 back, 5 forward).
    static func mouseBlock(_ hidButton: UInt8) -> [UInt8] { [0x01, 0x01, hidButton, 0, 0, 0, 0] }

    /// A consumer-control usage (volume, media keys), big-endian.
    static func consumerBlock(_ usage: UInt16) -> [UInt8] {
        [0x0A, 0x02, UInt8(usage >> 8), UInt8(usage & 0xFF), 0, 0, 0]
    }

    /// IOKit NX_KEYTYPE codes (`ButtonRemapper.mediaOptions`) as consumer-control usages.
    static let consumerUsages: [Int: UInt16] = [
        0: 0x00E9, // Volume Up
        1: 0x00EA, // Volume Down
        7: 0x00E2, // Mute
        16: 0x00CD, // Play / Pause
        17: 0x00B5, // Next Track
        18: 0x00B6, // Previous Track
    ]

    /// HyperShift while held: type 0C switches the mouse to its HyperShift layer
    /// (`shiftedPlan`), the job the side trigger has from the factory (0C 01 39). 0C 01 00, 01
    /// and 02 all did it on Side Front (press test with a layer-01 Volume Up, 2026-10-19).
    static let hyperShiftBlock: [UInt8] = [0x0C, 0x01, 0x01, 0, 0, 0, 0]

    // The blocks below were each written to a V4 Pro button and confirmed by pressing it
    // (2026-10-22). Their layouts are the Basilisk V3's, github.com/geezmolycos/razerqdhid
    // (docs/cmd_button-en.md, and public/py/qdrazer/protocol.py for the clutch, whose 05
    // the doc gives as 03).

    /// Double Click: type 0B repeats a mouse button's click; 01 is left.
    static let doubleClickBlock: [UInt8] = [0x0B, 0x01, 0x01, 0, 0, 0, 0]

    /// Turbo: type 0E clicks a mouse button (HID number), 0D presses a key (modifier bits,
    /// HID usage), each followed by the repeat interval in ms, big-endian. The tilt's factory
    /// 0E 01 68 00 14 is the same type, with length 01.
    static func turboClickBlock(hidButton: UInt8, intervalMs: Int) -> [UInt8] {
        [0x0E, 0x03, hidButton, UInt8(intervalMs >> 8 & 0xFF), UInt8(intervalMs & 0xFF), 0, 0]
    }

    static func turboKeyBlock(modifiers: UInt8, hidUsage: UInt8, intervalMs: Int) -> [UInt8] {
        [0x0D, 0x04, modifiers, hidUsage, UInt8(intervalMs >> 8 & 0xFF), UInt8(intervalMs & 0xFF), 0]
    }

    /// DPI Clutch: type 06 with sub-function 05, then X and Y DPI big-endian, held while the
    /// button is.
    static func dpiClutchBlock(dpi: Int) -> [UInt8] {
        let hi = UInt8(dpi >> 8 & 0xFF), lo = UInt8(dpi & 0xFF)
        return [0x06, 0x05, 0x05, hi, lo, hi, lo]
    }

    /// Cycle Scroll Mode: the wheel-mode button's factory function, on any button.
    static let cycleScrollModeBlock: [UInt8] = [0x12, 0x01, 0x01, 0, 0, 0, 0]

    /// The wheel's HID values in a mouse block: up, down, left, right.
    static let wheelValues: [ScrollDirection: UInt8] = [.up: 0x09, .down: 0x0A, .left: 0x68, .right: 0x69]

    /// A wheel step. Once per press is a mouse block (01 01 09 on any button); while held it
    /// is the tilt's own factory block, type 0E every 20 ms (0E 01 68 00 14). Sideways only
    /// the repeating form works: 01 01 68 and 69 sent nothing (2026-10-22), so a sideways
    /// scroll always repeats, as the tilt does.
    static func scrollBlock(_ direction: ScrollDirection, repeating: Bool) -> [UInt8]? {
        guard let value = wheelValues[direction] else { return nil }
        if direction.isVertical && !repeating { return mouseBlock(value) }
        guard repeating else { return nil }
        return [0x0E, 0x01, value, 0x00, 0x14, 0, 0]
    }

    /// DPI Stage Up or Down: type 06, 01 up and 02 down, stopping at the last stage (the DPI
    /// button's factory 06 wraps around). Both confirmed by pressing (2026-10-22).
    static func dpiStageBlock(up: Bool) -> [UInt8] { [0x06, 0x01, up ? 0x01 : 0x02, 0, 0, 0, 0] }

    /// What the mouse itself can do for an action, or nil when only MacRazer can (a key the
    /// mouse's keyboard format has no usage for). HyperShift is for the standard layer only
    /// (`shiftedPlan`).
    static func nativeBlock(for action: RemapAction) -> [UInt8]? {
        switch action {
        case .passthrough:
            return nil
        case .doubleClick:
            return doubleClickBlock
        case .hyperShift:
            return hyperShiftBlock
        case .turboClick(let button, let ms, _):
            guard (0...4).contains(button), (1...0xFFFF).contains(ms) else { return nil }
            return turboClickBlock(hidButton: UInt8(button + 1), intervalMs: ms)
        case .turboKey(let keyCode, let modifiers, _, let ms):
            // The keyboard block's modifier bits and usage, a lone modifier included.
            guard (1...0xFFFF).contains(ms),
                  let key = nativeBlock(for: .keystroke(keyCode: keyCode, modifiers: modifiers, name: "")) else { return nil }
            return turboKeyBlock(modifiers: key[2], hidUsage: key[3], intervalMs: ms)
        case .dpiClutch(let dpi):
            guard (100...0xFFFF).contains(dpi) else { return nil }
            return dpiClutchBlock(dpi: dpi)
        case .cycleScrollMode:
            return cycleScrollModeBlock
        case .scroll(let direction, let repeating):
            return scrollBlock(direction, repeating: repeating)
        case .dpiStage(let up):
            return dpiStageBlock(up: up)
        case .disabled:
            return disabledBlock
        case .keystroke(let keyCode, let modifiers, _):
            // A lone modifier is its HID modifier bit with no key, which is what a keyboard
            // sends for it (modkeytest, 2026-10-19: 02 02 08 00 made Side Back report a bare
            // Left ⌘, held for as long as the button is).
            if let bit = BLEProtocol.hidModifierBit(forMacKeyCode: keyCode) {
                return BLEProtocol.keyboardBlock(hidUsage: 0, modifiers: bit)
            }
            guard let usage = BLEProtocol.hidUsage(forMacKeyCode: keyCode) else { return nil }
            return BLEProtocol.keyboardBlock(hidUsage: usage,
                                             modifiers: DPIShortcutModifiers.hidValue(from: CGEventFlags(rawValue: modifiers)))
        case .mouseButton(let button, _):
            guard (0...4).contains(button) else { return nil }
            return mouseBlock(UInt8(button + 1))
        case .mediaKey(let code, _):
            return consumerUsages[code].map(consumerBlock)
        case .cycleProfile(let up):
            // Left Side's factory function is Cycle Up (Synapse's default map); 05 is Cycle
            // Down. Both moved between slots when pressed (2026-10-19).
            return [0x07, 0x01, up ? 0x04 : 0x05, 0, 0, 0, 0]
        }
    }

    // MARK: Reading the mouse

    /// The action a block in the mouse's table stands for, the reverse of `nativeBlock`:
    /// `.passthrough` for the control's factory function, nil for a block MacRazer can't
    /// write (a Synapse macro, a key it has no code for). Only blocks that `nativeBlock`
    /// writes back byte for byte are recognised, so reading one and syncing it is no write.
    static func action(for block: [UInt8], control: Control) -> RemapAction? {
        if block == control.factory { return .passthrough }
        guard block.count == 7 else { return nil }
        let candidate: RemapAction?
        let names = ["Left Click", "Right Click", "Middle Click", "Back", "Forward"]
        let interval = Int(block[3]) << 8 | Int(block[4])
        switch block[0] {
        case 0x01 where (1...5).contains(block[2]):
            candidate = .mouseButton(button: Int(block[2]) - 1, name: names[Int(block[2]) - 1])
        case 0x00:
            candidate = .disabled
        case 0x01 where block[2] == 0x09 || block[2] == 0x0A:
            candidate = .scroll(direction: block[2] == 0x09 ? .up : .down, repeating: false)
        case 0x0E where block[1] == 0x01:
            candidate = wheelValues.first { $0.value == block[2] }.map { .scroll(direction: $0.key, repeating: true) }
        case 0x06 where block[1] == 0x01 && (block[2] == 0x01 || block[2] == 0x02):
            candidate = .dpiStage(up: block[2] == 0x01)
        case 0x0B:
            candidate = .doubleClick
        case 0x0E where (1...5).contains(block[2]):
            candidate = .turboClick(button: Int(block[2]) - 1, intervalMs: interval, name: names[Int(block[2]) - 1])
        case 0x0D:
            if case .keystroke(let keyCode, let modifiers, let name)? = keystroke(hidUsage: block[3], modifiers: block[2]) {
                candidate = .turboKey(keyCode: keyCode, modifiers: modifiers, name: name,
                                      intervalMs: Int(block[4]) << 8 | Int(block[5]))
            } else {
                candidate = nil
            }
        case 0x06 where block[1] == 0x05 && block[2] == 0x05:
            candidate = .dpiClutch(dpi: interval)
        case 0x12:
            candidate = .cycleScrollMode
        case 0x02:
            candidate = keystroke(hidUsage: block[3], modifiers: block[2])
        case 0x07 where block[2] == 0x04 || block[2] == 0x05:
            candidate = .cycleProfile(up: block[2] == 0x04)
        case 0x0A:
            let usage = UInt16(block[2]) << 8 | UInt16(block[3])
            candidate = consumerUsages.first { $0.value == usage }.flatMap { code, _ in
                ButtonRemapper.mediaOptions.first { $0.code == code }.map { .mediaKey(code: $0.code, name: $0.name) }
            }
        case 0x0C:
            candidate = .hyperShift
        default:
            candidate = nil
        }
        return candidate.flatMap { nativeBlock(for: $0) == block ? $0 : nil }
    }

    /// A keyboard block as a keystroke, named the way the key recorder names it (or as the
    /// preset it matches).
    private static func keystroke(hidUsage: UInt8, modifiers: UInt8) -> RemapAction? {
        if hidUsage == 0 {
            // A lone modifier key, left and right apart.
            guard let keyCode = (0...127).map(UInt16.init).first(where: { BLEProtocol.hidModifierBit(forMacKeyCode: $0) == modifiers }),
                  let name = RecorderNSView.modifierKeys[keyCode]?.name else { return nil }
            return .keystroke(keyCode: keyCode, modifiers: 0, name: name)
        }
        guard let keyCode = (0...127).map(UInt16.init).first(where: { BLEProtocol.hidUsage(forMacKeyCode: $0) == hidUsage })
        else { return nil }
        var flags = CGEventFlags()
        if modifiers & 0x01 != 0 { flags.insert(.maskControl) }
        if modifiers & 0x02 != 0 { flags.insert(.maskShift) }
        if modifiers & 0x04 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 0x08 != 0 { flags.insert(.maskCommand) }
        if let preset = ButtonRemapper.presets.first(where: { $0.keyCode == keyCode && $0.flags == flags }) {
            return preset.action
        }
        return .keystroke(keyCode: keyCode, modifiers: flags.rawValue,
                          name: BLEProtocol.shortcutLabel(hidUsage: hidUsage, modifiers: modifiers))
    }

    /// The remap table with each control's entries set to what the mouse holds, standard
    /// layer and HyperShift layer: the mouse is where remaps live, so a remap made on another
    /// computer (or a fresh install's empty table) gives way to it. `standard` and `shifted`
    /// are the blocks read, by table id; a shifted entry read as unset is the factory
    /// function. A control missing from a read keeps its mapping. Kept as they are: a mapping
    /// that already writes what the mouse holds (its name included), and an action only
    /// MacRazer can do (Double Click) on a control the mouse still has on its factory function.
    static func adopt(pid: Int, mappings: [Int: RemapAction],
                      standard: [UInt8: [UInt8]], shifted: [UInt8: [UInt8]?]) -> [Int: RemapAction] {
        guard let controls = layout(pid: pid) else { return mappings }
        var out = mappings
        func take(_ key: Int, read: [UInt8], control: Control, shiftedLayer: Bool) {
            let local = mappings[key] ?? .passthrough
            if local != .passthrough, nativeBlock(for: local) == read, !(shiftedLayer && local == .hyperShift) { return }
            var found = action(for: read, control: control)
            if shiftedLayer, found == .hyperShift { found = nil }
            switch found {
            case .passthrough?:
                if !shiftedLayer, local != .passthrough, placement(for: control, mappings: [key: local]) == .app { return }
                out.removeValue(forKey: key)
            case let action?:
                out[key] = action
            case nil:
                // Something MacRazer can't show; the row reads as factory and the entry is
                // left alone (`step`).
                out.removeValue(forKey: key)
            }
        }
        for control in controls {
            if let read = standard[control.tableID] {
                take(control.button, read: read, control: control, shiftedLayer: false)
            }
            if let read = shifted[control.tableID] {
                take(ButtonRemapper.hyperShiftKey(control.button), read: read ?? control.factory, control: control, shiftedLayer: true)
            }
        }
        return out
    }

    // MARK: Plan

    /// Where a control's remap lives.
    enum Placement: Equatable, Sendable {
        /// Nothing remapped: the mouse's own function.
        case factory
        /// Saved in the mouse as this block.
        case mouse([UInt8])
        /// Only MacRazer can do it, so the entry keeps its factory function and the event tap
        /// acts on the presses (`appSees`).
        case app
    }

    struct Entry: Equatable, Sendable {
        let control: Control
        let placement: Placement
    }

    /// Every control's placement for a remap table's standard layer. HyperShift mappings go
    /// to the mouse's own HyperShift layer (`shiftedPlan`), switched by the side trigger and
    /// by any control set to HyperShift (`hyperShiftBlock`).
    static func plan(pid: Int, mappings: [Int: RemapAction]) -> [Entry] {
        guard let controls = layout(pid: pid) else { return [] }
        return controls.map { Entry(control: $0, placement: placement(for: $0, mappings: mappings)) }
    }

    static func placement(for control: Control, mappings: [Int: RemapAction]) -> Placement {
        let action = mappings[control.button] ?? .passthrough
        if isFactory(action, on: control) { return .factory }
        return nativeBlock(for: action).map(Placement.mouse) ?? .app
    }

    /// Whether an action is what the control already does from the factory: no remap, its
    /// own block, or HyperShift on the side trigger (whose 0C 01 39 differs from
    /// `hyperShiftBlock` in its sub-function byte only).
    static func isFactory(_ action: RemapAction, on control: Control) -> Bool {
        action == .passthrough || nativeBlock(for: action) == control.factory
            || (action == .hyperShift && isHyperShiftOnFactory(control))
    }

    // MARK: HyperShift layer

    /// The mouse keeps a second function table, its HyperShift layer, used while the side
    /// trigger (Synapse's HyperShift clutch) is held: 02/0C with the third argument 01
    /// (`RazerCommands.setButtonFunction(_:block:layer:)`), read with 02/8C and the same
    /// argument. Confirmed on the V4 Pro over the dongle: Volume Up written to Side Back's
    /// layer 01 fired only with the trigger held, left the standard layer alone, and read back
    /// with layer 01 (hslayerread, 2026-10-19). Over Bluetooth the same layer byte goes in the
    /// write's payload, and every read carries the layer (bthstest, 2026-10-19).
    ///
    /// A control's HyperShift entry: its remap there, or `.factory` (left as the mouse has
    /// it, which from the factory is the same function as the standard layer). Actions only
    /// MacRazer can do don't exist on this layer, and neither does HyperShift itself.
    static func shiftedPlan(pid: Int, mappings: [Int: RemapAction]) -> [Entry] {
        guard let controls = layout(pid: pid) else { return [] }
        return controls.map { control in
            let action = mappings[ButtonRemapper.hyperShiftKey(control.button)] ?? .passthrough
            guard action != .hyperShift else { return Entry(control: control, placement: .factory) }
            return Entry(control: control, placement: nativeBlock(for: action).map(Placement.mouse) ?? .factory)
        }
    }

    /// Brings the mouse's HyperShift layer in line with a plan, the same way `sync` does the
    /// standard layer (`step`). An entry nothing was written to reads as the control's
    /// factory function, which is what the mouse does with it.
    /// `current` is the layer as just read, by table id, which saves reading it again.
    static func syncShifted(_ table: ButtonFunctionTable, plan: [Entry],
                            owned start: [UInt8: Set<[UInt8]>],
                            current: [UInt8: [UInt8]?]? = nil) -> (owned: [UInt8: Set<[UInt8]>], failed: Int) {
        var owned = start
        var failed = 0
        for entry in plan {
            let id = entry.control.tableID
            // Not `try?`: it would flatten an unset entry (nil) into a failed read.
            let read: [UInt8]?
            if let known = current?[id] {
                read = known
            } else {
                do { read = try table.readShiftedBlock(id) } catch { failed += 1; continue }
            }
            let step = step(entry.placement, current: read ?? entry.control.factory,
                            factory: entry.control.factory, owned: owned[id] ?? [])
            if let block = step.write {
                guard (try? table.writeShiftedBlock(id, block: block)) != nil else {
                    owned[id] = step.ownedIfFailed
                    failed += 1
                    continue
                }
            }
            owned[id] = step.owned
        }
        return (owned, failed)
    }

    // MARK: Sync

    /// What to do with one entry. `write` is the block to put in it (nil: leave it as it is);
    /// `owned` is the blocks MacRazer may have left in it afterwards, which is what lets it
    /// put the entry back later. A failed write counts the block it tried, since the mouse
    /// may hold it anyway.
    struct Step: Equatable {
        let write: [UInt8]?
        let owned: Set<[UInt8]>
        /// What `owned` becomes when the write fails.
        let ownedIfFailed: Set<[UInt8]>
    }

    /// One entry's step. Only an entry MacRazer wrote is ever put back: one that holds
    /// something else was set some other way (Synapse on another computer) and is left alone.
    static func step(_ placement: Placement, current: [UInt8], factory: [UInt8], owned: Set<[UInt8]>) -> Step {
        switch placement {
        case .mouse(let block):
            guard current != block else { return Step(write: nil, owned: [block], ownedIfFailed: [block]) }
            return Step(write: block, owned: [block], ownedIfFailed: owned.union([block]))
        case .factory, .app:
            let ours = owned.contains(current)
            guard ours, current != factory else { return Step(write: nil, owned: [], ownedIfFailed: []) }
            return Step(write: factory, owned: [], ownedIfFailed: owned.union([current]))
        }
    }

    /// Brings a mouse's table in line with a plan, reading each entry first, or taking it
    /// from `current` when the table was just read; a write is checked by reading it back
    /// (`ButtonFunctionTable.writeButtonBlock`). Returns what MacRazer owns afterwards and
    /// how many entries failed to read or write.
    static func sync(_ table: ButtonFunctionTable, plan: [Entry],
                     owned start: [UInt8: Set<[UInt8]>],
                     current known: [UInt8: [UInt8]]? = nil) -> (owned: [UInt8: Set<[UInt8]>], failed: Int) {
        var owned = start
        var failed = 0
        for entry in plan {
            let id = entry.control.tableID
            guard let current = known?[id] ?? (try? table.readButtonBlock(id)) else { failed += 1; continue }
            let step = step(entry.placement, current: current, factory: entry.control.factory, owned: owned[id] ?? [])
            if let block = step.write {
                guard (try? table.writeButtonBlock(id, block: block)) != nil else {
                    owned[id] = step.ownedIfFailed
                    failed += 1
                    continue
                }
            }
            owned[id] = step.owned
        }
        return (owned, failed)
    }
}

/// Which blocks MacRazer wrote into which mouse's function table, by serial number, so only
/// those are ever put back (`OnboardButtons.step`).
struct OnboardOwnership {
    static let defaultsKey = "onboardButtonsOwned"
    let defaults: UserDefaults

    /// The record of a mouse's HyperShift layer (`OnboardButtons.shiftedPlan`).
    static func shiftedKey(serial: String) -> String { serial + "#hypershift" }

    func owned(serial: String) -> [UInt8: Set<[UInt8]>] {
        guard let all = defaults.dictionary(forKey: Self.defaultsKey),
              let mouse = all[serial] as? [String: [Data]] else { return [:] }
        var out: [UInt8: Set<[UInt8]>] = [:]
        for (id, blocks) in mouse {
            guard let id = UInt8(id, radix: 16) else { continue }
            out[id] = Set(blocks.map { Array($0) })
        }
        return out
    }

    func set(_ owned: [UInt8: Set<[UInt8]>], serial: String) {
        var all = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        let mouse = owned.filter { !$0.value.isEmpty }
        if mouse.isEmpty {
            all.removeValue(forKey: serial)
        } else {
            all[serial] = Dictionary(uniqueKeysWithValues: mouse.map { id, blocks in
                (String(format: "%02X", id), blocks.sorted { $0.lexicographicallyPrecedes($1) }.map { Data($0) })
            })
        }
        defaults.set(all, forKey: Self.defaultsKey)
    }
}

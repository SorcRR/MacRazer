// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import ApplicationServices

/// What a remapped button does. `.passthrough` lets the original event through; `.keystroke`
/// suppresses the button and posts a key combo instead.
enum RemapAction: Codable, Equatable {
    case passthrough
    case keystroke(keyCode: UInt16, modifiers: UInt64, name: String)
    case mouseButton(button: Int, name: String)
    case doubleClick
    case mediaKey(code: Int, name: String)

    var label: String {
        switch self {
        case .passthrough: return "None"
        case .keystroke(_, _, let name), .mouseButton(_, let name), .mediaKey(_, let name): return name
        case .doubleClick: return "Double Click"
        }
    }
}

/// A curated shortcut a button can be bound to (keeps v1 simple — no key recorder yet).
struct RemapPreset: Identifiable {
    let id: String
    let name: String
    let keyCode: UInt16
    let flags: CGEventFlags

    var action: RemapAction { .keystroke(keyCode: keyCode, modifiers: flags.rawValue, name: name) }
}

/// Software button remapping via a CGEvent tap. Detects which extra mouse buttons fire and,
/// for mapped ones, suppresses the original event and posts a key combo instead.
///
/// This is the legal/portable approach (no Razer protocol). It only works while the app runs
/// and needs Accessibility permission. Onboard remapping would require reverse-engineering
/// Synapse, which Razer's EULA forbids — see the research notes.
final class ButtonRemapper: ObservableObject, @unchecked Sendable {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var lastDetectedButton: Int?
    @Published private(set) var seenButtons: Set<Int> = []
    @Published private(set) var mappings: [Int: RemapAction] = [:]

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Per-device key so each mouse keeps its own remaps.
    private var activeKey = "none"
    private var defaultsKey: String { "buttonMappings-\(activeKey)" }
    /// Mirrors `MouseController.connected` (wired in AppDelegate; main-thread, same as the
    /// tap callback). While the mouse is offline — powered off, asleep, dongle unplugged —
    /// its mappings must not fire: the tap can't tell which device sent a click, so they'd
    /// keep remapping matching buttons on every other pointing device. Published so the
    /// remap UI can say why nothing is firing (button detection still works while paused).
    @Published var remappingPaused = false

    /// Switch to the connected mouse's mappings (called when the device changes). `key` is the
    /// per-unit device key (serial/PID).
    func setActiveDevice(_ key: String?) {
        let k = key ?? "none"
        guard k != activeKey else { return }
        activeKey = k
        seenButtons = [] // detected buttons are per-device
        loadMappings()
    }

    static let presets: [RemapPreset] = [
        .init(id: "copy", name: "Copy  ⌘C", keyCode: 8, flags: .maskCommand),
        .init(id: "paste", name: "Paste  ⌘V", keyCode: 9, flags: .maskCommand),
        .init(id: "cut", name: "Cut  ⌘X", keyCode: 7, flags: .maskCommand),
        .init(id: "undo", name: "Undo  ⌘Z", keyCode: 6, flags: .maskCommand),
        .init(id: "redo", name: "Redo  ⇧⌘Z", keyCode: 6, flags: [.maskCommand, .maskShift]),
        .init(id: "selectAll", name: "Select All  ⌘A", keyCode: 0, flags: .maskCommand),
        .init(id: "save", name: "Save  ⌘S", keyCode: 1, flags: .maskCommand),
        .init(id: "find", name: "Find  ⌘F", keyCode: 3, flags: .maskCommand),
        .init(id: "newTab", name: "New Tab  ⌘T", keyCode: 17, flags: .maskCommand),
        .init(id: "close", name: "Close  ⌘W", keyCode: 13, flags: .maskCommand),
        .init(id: "back", name: "Back  ⌘[", keyCode: 33, flags: .maskCommand),
        .init(id: "forward", name: "Forward  ⌘]", keyCode: 30, flags: .maskCommand),
        .init(id: "missionControl", name: "Mission Control  ⌃↑", keyCode: 126, flags: .maskControl),
        .init(id: "spaceLeft", name: "Space Left  ⌃←", keyCode: 123, flags: .maskControl),
        .init(id: "spaceRight", name: "Space Right  ⌃→", keyCode: 124, flags: .maskControl),
        .init(id: "screenshot", name: "Screenshot  ⇧⌘4", keyCode: 21, flags: [.maskCommand, .maskShift]),
        .init(id: "switchApp", name: "Switch App  ⌘Tab", keyCode: 48, flags: .maskCommand),
    ]

    // MARK: - Lifecycle

    func start() {
        loadMappings()
        refreshAccessibility(prompt: false)
        if accessibilityGranted { installTap() }
    }

    /// Re-check the Accessibility grant (call when the window appears / returns to front).
    func refreshAccessibility(prompt: Bool) {
        // Use the literal key to avoid touching the non-Sendable global CFString symbol.
        let granted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
        accessibilityGranted = granted
        if granted && tap == nil {
            installTap()
        } else if !granted && tap != nil {
            removeTap()
        }
    }

    /// Tears down the event tap and its run-loop source — called when Accessibility is revoked
    /// while the app is running, so a stale tap isn't left registered indefinitely.
    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    func openAccessibilitySettings() { SystemSettingsPanes.openAccessibility() }

    // MARK: - Mappings

    /// Media keys (IOKit NX_KEYTYPE codes).
    static let mediaOptions: [(code: Int, name: String)] = [
        (16, "Play / Pause"), (17, "Next Track"), (18, "Previous Track"),
        (0, "Volume Up"), (1, "Volume Down"), (7, "Mute"),
    ]

    /// Called after an individual button's mapping changes — lets owners (e.g. profile tracking
    /// in `MouseController`) know the live config has drifted from whatever profile was applied.
    var onManualChange: (() -> Void)?

    func setAction(_ action: RemapAction, for button: Int) {
        mappings[button] = action
        seenButtons.insert(button)
        saveMappings()
        onManualChange?()
    }

    /// Replaces the whole mapping table at once — used when applying a saved profile (as opposed
    /// to a single-button edit from the remap UI, which goes through `setAction`).
    func setMappings(_ new: [Int: RemapAction]) {
        mappings = new
        seenButtons.formUnion(new.keys)
        saveMappings()
    }

    func actionLabel(for button: Int) -> String { mappings[button]?.label ?? "None" }

    /// Friendly, compact label for a raw CGEvent button number.
    static func label(for button: Int) -> String {
        switch button {
        case 2: return "Wheel Click"
        case 3: return "Back (4)"
        case 4: return "Forward (5)"
        default: return "Button \(button + 1)"
        }
    }

    /// Mock state for the `render-remap` preview command.
    func loadPreviewState() {
        accessibilityGranted = true
        seenButtons = [2, 3, 4, 5]
        mappings = [3: .keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy  ⌘C")]
    }

    // MARK: - Event tap

    private func installTap() {
        // otherMouse = middle/wheel-click + extra buttons — the only events we remap.
        // Primary left/right clicks are deliberately never tapped.
        let types: [CGEventType] = [.otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = src
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let remapper = Unmanaged<ButtonRemapper>.fromOpaque(userInfo).takeUnretainedValue()
        return remapper.handle(type: type, event: event)
    }

    private static let magic: Int64 = 0x52415A45 // "RAZE" — marks events we post, to skip them
    private lazy var postSource: CGEventSource? = {
        let s = CGEventSource(stateID: .combinedSessionState)
        s?.userData = Self.magic
        return s
    }()

    /// Runs on the main run loop (the tap source is scheduled there).
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Skip events we ourselves posted (e.g. a remap-to-middle-click re-enters the tap).
        if event.getIntegerValueField(.eventSourceUserData) == Self.magic {
            return Unmanaged.passUnretained(event)
        }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))

        // Only the extra buttons are remappable (the tap is scoped to otherMouse events,
        // but keep the guard as a defensive net).
        guard type == .otherMouseDown || type == .otherMouseUp else {
            return Unmanaged.passUnretained(event)
        }

        if !remappingPaused, let action = mappings[button], action != .passthrough {
            if type == .otherMouseDown { apply(action) }
            return nil // suppress the original button (both down and up)
        }

        // Unmapped → remember it for the UI, and let it through unchanged.
        if type == .otherMouseDown, lastDetectedButton != button || !seenButtons.contains(button) {
            lastDetectedButton = button
            seenButtons.insert(button)
        }
        return Unmanaged.passUnretained(event)
    }

    private func apply(_ action: RemapAction) {
        switch action {
        case .passthrough: break
        case .keystroke(let kc, let mods, _): postKeystroke(keyCode: kc, flags: CGEventFlags(rawValue: mods))
        case .mouseButton(let b, _): postMouseClick(b)
        case .doubleClick: postDoubleClick()
        case .mediaKey(let code, _): postMediaKey(code)
        }
    }

    private func postKeystroke(keyCode: UInt16, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: postSource, virtualKey: CGKeyCode(keyCode), keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: postSource, virtualKey: CGKeyCode(keyCode), keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    private func postMouseClick(_ button: Int) {
        let pos = CGEvent(source: nil)?.location ?? .zero
        let mb = CGMouseButton(rawValue: UInt32(button)) ?? .center
        let downType: CGEventType = button == 0 ? .leftMouseDown : (button == 1 ? .rightMouseDown : .otherMouseDown)
        let upType: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
        for (type, clickState) in [(downType, 1), (upType, 1)] {
            let e = CGEvent(mouseEventSource: postSource, mouseType: type, mouseCursorPosition: pos, mouseButton: mb)
            // Without a click count, apps reading NSEvent.clickCount see 0 and may not
            // treat the synthesized press as a click at all (e.g. middle-click-closes-tab).
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            e?.post(tap: .cghidEventTap)
        }
    }

    private func postDoubleClick() {
        let pos = CGEvent(source: nil)?.location ?? .zero
        for clicks in [1, 2] {
            let down = CGEvent(mouseEventSource: postSource, mouseType: .leftMouseDown, mouseCursorPosition: pos, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(mouseEventSource: postSource, mouseType: .leftMouseUp, mouseCursorPosition: pos, mouseButton: .left)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            up?.post(tap: .cghidEventTap)
        }
    }

    private func postMediaKey(_ code: Int) {
        func post(_ down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (code << 16) | ((down ? 0xA : 0xB) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                               timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(true); post(false)
    }

    // MARK: - Persistence

    private func saveMappings() {
        // No connected device, no persistence: an edit made in a remap window that outlived
        // a disconnect would otherwise be saved under the meaningless "none" key and
        // silently dropped on reconnect.
        guard activeKey != "none" else { return }
        if let data = try? JSONEncoder().encode(mappings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func loadMappings() {
        // Always reset first: a device with no saved table must start empty rather than
        // inherit the previous mouse's mappings — which would both remap the new mouse with
        // the old one's bindings and, on the next edit, save the old table under the new
        // device's key. Also covers disconnect (key "none"): with no mappings the tap
        // passes everything through.
        mappings = [:]
        // Never load under the no-device key. Nothing writes it anymore (see saveMappings),
        // but pre-fix builds persisted disconnected edits there — clear that junk out so it
        // can't remap other pointing devices on every launch/disconnect forever.
        guard activeKey != "none" else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Int: RemapAction].self, from: data) else { return }
        mappings = decoded
        seenButtons.formUnion(decoded.keys)
    }
}

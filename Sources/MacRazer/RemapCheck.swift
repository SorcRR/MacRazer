// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import Darwin

/// What on this Mac can get between a mouse's buttons and MacRazer's remapping, for the
/// device test's button step and its report.
///
/// Razer's own software first: Synapse and its helpers can grab the side buttons, or save
/// them on the mouse as something else. Then any app whose event tap can drop an extra-button
/// click before MacRazer's sees it (`ButtonRemapper.competingTapPIDs`).
///
/// Names only, never the rest of the process list: the report carries just what matched.
enum RemapSoftware {
    /// At most this many names of each kind, each at most `maxNameLength` characters.
    static let maxNames = 16
    static let maxNameLength = 64

    /// Every process now running, matched against `razerName`, and the apps with a competing
    /// mouse tap.
    static func scan() -> DeviceReport.SoftwareData {
        let own = getpid()
        var razer: [String] = []
        for pid in allPIDs() where pid != own {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  let name = razerName(executablePath: String(cString: buffer)) else { continue }
            razer.append(name)
        }
        return .init(razer: tidy(razer), mouseTaps: tidy(ButtonRemapper.currentCompetingTapApps()))
    }

    /// The name to report for a Razer process, or nil for anything else. Matched on the path
    /// rather than a list of names: Razer renames its helpers between Synapse versions, and
    /// they all live in a folder or app named for Razer (Razer Synapse.app,
    /// /Library/Application Support/Razer, com.razer.*). A folder that only contains the word,
    /// like a project called razer-tools or a home folder called frazer, doesn't count.
    /// MacRazer itself, and macOS's own folders, never match.
    static func razerName(executablePath path: String) -> String? {
        guard !path.hasPrefix("/System/"), !path.hasPrefix("/usr/") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard let executable = components.last,
              !components.contains(where: { $0.range(of: "macrazer", options: .caseInsensitive) != nil }),
              components.contains(where: isRazerFolder) else { return nil }
        // The outermost app names it, as Activity Monitor would. A daemon outside any app
        // goes by its executable.
        if let app = components.first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        return executable
    }

    /// "Razer", "Razer Synapse.app", "com.razer.rzupdater": a name that is Razer's, not one
    /// that merely has the word in it.
    private static func isRazerFolder(_ component: String) -> Bool {
        let name = component.lowercased()
        return name == "razer" || name.hasPrefix("razer ") || name.hasPrefix("com.razer")
            || (name.hasPrefix("razer") && name.hasSuffix(".app"))
    }

    /// Distinct, sorted and capped, so the report stays small and the same set reads the same.
    static func tidy(_ names: [String]) -> [String] {
        Array(Set(names.map { String($0.prefix(maxNameLength)) })).sorted().prefix(maxNames).map { $0 }
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }
    }
}

// MARK: - Keys

/// The keys pressed while the button step's "record keyboard keys" is on, as the report keeps
/// them: each distinct key with its modifiers, nothing about order or timing. Pure, so the
/// rules are tested without a tap.
///
/// A side button set on the mouse to send Ctrl+C arrives as an ordinary key press, the same
/// as the keyboard's, which is why the person is asked to press only the mouse while it's on.
struct KeystrokeLog: Equatable {
    /// Enough for every button of a 12-button side panel twice over, and a hard stop for
    /// someone who forgot it was on and typed.
    static let maxKeys = 32

    private(set) var keys: Set<DeviceReport.KeyPress> = []
    /// A modifier key that went down with nothing pressed while it was held yet. A side
    /// button set to Shift alone is recorded when it comes back up.
    private var pendingModifier: DeviceReport.KeyPress?
    private var heldModifiers: Set<String> = []

    var sorted: [DeviceReport.KeyPress] { keys.sorted() }

    /// A key went down. Auto-repeats add nothing.
    mutating func keyDown(keyCode: Int, flags: CGEventFlags, autorepeat: Bool, postedBy: String?) {
        pendingModifier = nil
        guard !autorepeat else { return }
        insert(.init(keyCode: keyCode, modifiers: Self.modifiers(flags), postedBy: postedBy))
    }

    /// A modifier went down or up.
    mutating func flagsChanged(keyCode: Int, flags: CGEventFlags, postedBy: String?) {
        let now = Set(Self.modifiers(flags))
        defer { heldModifiers = now }
        if now.count > heldModifiers.count {
            pendingModifier = .init(keyCode: keyCode, modifiers: Self.modifiers(flags), postedBy: postedBy)
        } else if let pending = pendingModifier, pending.keyCode == keyCode {
            insert(pending)
            pendingModifier = nil
        }
    }

    private mutating func insert(_ key: DeviceReport.KeyPress) {
        guard keys.count < Self.maxKeys || keys.contains(key) else { return }
        keys.insert(key)
    }

    /// The modifiers held, in the order macOS menus write them. Fn is left out: macOS sets it
    /// on every arrow and function key, where it says nothing about the button.
    static func modifiers(_ flags: CGEventFlags) -> [String] {
        [(CGEventFlags.maskControl, "control"), (.maskAlternate, "option"),
         (.maskShift, "shift"), (.maskCommand, "command")]
            .filter { flags.contains($0.0) }.map(\.1)
    }
}

extension DeviceReport.KeyPress {
    /// How the step's list and the review show it: "⌃V", "⌘⇧4", "Shift". Key names are for
    /// a US layout; the report keeps the key code, which doesn't depend on one.
    var displayName: String {
        let name = Self.keyNames[keyCode] ?? String(format: "Key %d", keyCode)
        if Self.modifierKeyCodes.contains(keyCode) { return name }
        let symbols = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
        return modifiers.compactMap { symbols[$0] }.joined() + name
    }

    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// macOS virtual key codes (Carbon's kVK_ constants) on a US keyboard.
    static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
        50: "`", 51: "Delete", 53: "Esc", 54: "Right Command", 55: "Command", 56: "Shift",
        57: "Caps Lock", 58: "Option", 59: "Control", 60: "Right Shift", 61: "Right Option",
        62: "Right Control", 63: "Fn", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End", 120: "F2",
        121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

/// A listen-only event tap on key presses, for the button step's "record keyboard keys".
///
/// The session's event stream rather than the mouse's own HID interfaces (`ButtonCapture`
/// already listens there): it also hears keys a side button sends through a part of the
/// mouse `ButtonCapture` doesn't open, and keys software posts for a button, which is how
/// Synapse and other remappers turn a click into a shortcut. Listen-only, so it can't change
/// or drop anything, and it needs Input Monitoring, not Accessibility.
///
/// Main thread only, like the run loop it schedules on.
final class KeystrokeCapture: @unchecked Sendable {
    enum StartResult: Equatable {
        case started
        /// Input Monitoring isn't granted. macOS has been asked, the first time.
        case denied
        /// macOS wouldn't create the tap.
        case failed
    }

    private let onKey: (Event) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// `postedBy`'s answer per process, so a burst of posted keys costs one lookup.
    private var appNames: [pid_t: String?] = [:]

    enum Event {
        case keyDown(keyCode: Int, flags: CGEventFlags, autorepeat: Bool, postedBy: String?)
        case flagsChanged(keyCode: Int, flags: CGEventFlags, postedBy: String?)
    }

    init(onKey: @escaping (Event) -> Void) {
        self.onKey = onKey
    }

    /// The tap holds only an unretained pointer to the capture, so dropping the last
    /// reference always ends it: a path that forgets `stop()` can't leave it listening.
    deinit { stop() }

    var isRunning: Bool { tap != nil }

    func start() -> StartResult {
        guard !isRunning else { return .started }
        guard CGPreflightListenEventAccess() else {
            _ = CGRequestListenEventAccess()
            return .denied
        }
        // Unretained: the owner keeps the capture alive, and deinit removes the tap first.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: Self.callback, userInfo: context)
        else { return .failed }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return .started
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let capture = Unmanaged<KeystrokeCapture>.fromOpaque(userInfo).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = capture.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            capture.onKey(.keyDown(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
                                   autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                   postedBy: capture.postedBy(event)))
        case .flagsChanged:
            capture.onKey(.flagsChanged(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                                        flags: event.flags, postedBy: capture.postedBy(event)))
        default: break
        }
        return Unmanaged.passUnretained(event)
    }

    /// The app that posted a key, for one that didn't come from a keyboard or mouse: the
    /// sign of a remapper at work. Nil for a key from hardware.
    private func postedBy(_ event: CGEvent) -> String? {
        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        if pid > 0 {
            if appNames[pid] == nil {
                appNames[pid] = .some(ButtonRemapper.appName(pid: pid).map { String($0.prefix(RemapSoftware.maxNameLength)) })
            }
            if let name = appNames[pid] ?? nil { return name }
        }
        let state = event.getIntegerValueField(.eventSourceStateID)
        return state == Int64(CGEventSourceStateID.hidSystemState.rawValue) ? nil : "unknown"
    }
}

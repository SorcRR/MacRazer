// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import ApplicationServices
import CoreGraphics

/// What a remapped button does. `.passthrough` lets the original event through; `.keystroke`
/// suppresses the button and posts a key combo instead.
enum RemapAction: Codable, Equatable, Sendable {
    case passthrough
    case keystroke(keyCode: UInt16, modifiers: UInt64, name: String)
    case mouseButton(button: Int, name: String)
    case doubleClick
    case mediaKey(code: Int, name: String)
    /// Held, it switches every other button to its HyperShift mapping
    /// (`ButtonRemapper.hyperShiftKey`), like Synapse's HyperShift. Does nothing by itself.
    case hyperShift
    /// Moves the mouse to its next (or previous) onboard profile slot (`OnboardSlots`).
    /// The mouse does it itself; on mice without slots it is never offered.
    case cycleProfile(up: Bool)
    // The rest are done by the mouse itself and only offered on a mouse that keeps its
    // remaps (`OnboardButtons.nativeBlock`).
    /// A mouse button (0 left ... 4 forward) clicked over and over while held, every
    /// `intervalMs`.
    case turboClick(button: Int, intervalMs: Int, name: String)
    /// A key or combination pressed over and over while held, every `intervalMs`.
    case turboKey(keyCode: UInt16, modifiers: UInt64, name: String, intervalMs: Int)
    /// The mouse runs at `dpi` while held, then goes back (Synapse's Sensitivity Clutch).
    case dpiClutch(dpi: Int)
    /// Cycles the wheel's modes, the wheel-mode button's factory job.
    case cycleScrollMode
    /// A wheel step, once per press or `repeating` while held. Sideways the mouse only
    /// repeats (`OnboardButtons.scrollBlock`).
    case scroll(direction: ScrollDirection, repeating: Bool)
    /// One DPI stage up or down, stopping at the ends.
    case dpiStage(up: Bool)
    /// The button does nothing.
    case disabled

    var label: String {
        switch self {
        case .passthrough: return "None"
        case .keystroke(_, _, let name), .mouseButton(_, let name), .mediaKey(_, let name): return name
        case .doubleClick: return "Double Click"
        case .hyperShift: return "HyperShift"
        case .cycleProfile(let up): return up ? "Cycle Up Profile" : "Cycle Down Profile"
        case .turboClick(_, let ms, let name): return "Turbo \(name) (\(Self.perSecond(ms))/s)"
        case .turboKey(_, _, let name, let ms): return "Turbo \(name) (\(Self.perSecond(ms))/s)"
        case .dpiClutch(let dpi): return "DPI Clutch \(dpi)"
        case .cycleScrollMode: return "Cycle Scroll Mode"
        case .scroll(let direction, let repeating):
            return (repeating && direction.isVertical ? "Repeat " : "") + direction.label
        case .dpiStage(let up): return up ? "DPI Stage Up" : "DPI Stage Down"
        case .disabled: return "Disabled"
        }
    }

    /// The turbo rates the remap menu offers, as presses per second.
    static let turboRates = [5, 10, 20]
    /// The DPI values the remap menu offers for the clutch.
    static let clutchDPIs = [400, 800, 1200, 1600]

    static func intervalMs(perSecond rate: Int) -> Int { 1000 / rate }
    static func perSecond(_ intervalMs: Int) -> Int { intervalMs > 0 ? 1000 / intervalMs : 0 }
}

/// Which way a `.scroll` remap scrolls.
enum ScrollDirection: String, Codable, CaseIterable, Sendable {
    case up, down, left, right

    var label: String { "Scroll " + rawValue.capitalized }
    var isVertical: Bool { self == .up || self == .down }
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
/// It only works while the app runs and needs Accessibility permission. A mouse whose
/// function table is known (`OnboardButtons`) keeps its remaps itself; the tap then only
/// handles what the mouse can't store (Double Click).
final class ButtonRemapper: ObservableObject, @unchecked Sendable {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var eventTapAvailable = false
    @Published private(set) var keyboardCaptureAvailable = false
    @Published private(set) var lastDetectedButton: Int?
    @Published private(set) var seenButtons: Set<Int> = []
    @Published private(set) var suggestedButtons: Set<Int> = []
    @Published private(set) var mappings: [Int: RemapAction] = [:] {
        didSet { refreshOnboardPlan() }
    }

    @Published private(set) var dpiCycleSoftwareAction: RemapAction?
    @Published private(set) var dpiBridgeBindingConfirmed = false
    private var bridgeKeyIsDown = false
    private var dpiBridgeReadRequested = false
    private var dpiBridgeRestoreAttempted = false
    private var dpiObservers = Set<AnyCancellable>()
    private let defaults: UserDefaults
    private let actionEmitter: ((RemapAction) -> Void)?

    init(defaults: UserDefaults = .standard, actionEmitter: ((RemapAction) -> Void)? = nil) {
        self.defaults = defaults
        self.actionEmitter = actionEmitter
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapIncludesKeyboard = false
    /// Per-device key so each mouse keeps its own remaps.
    private var activeKey = "none"
    private var activeDeviceID: Int?
    var isBasiliskV3XHyperSpeed: Bool {
        activeKey != "none" && (activeDeviceID.map(RazerDevices.supportsDpiButtonBinding(pid:)) ?? false)
    }
    var remappingPermissionsGranted: Bool { accessibilityGranted && eventTapAvailable }
    private var defaultsKey: String { "buttonMappings-\(activeKey)" }
    /// Mirrors `MouseController.connected` (wired in AppDelegate; main-thread, same as the
    /// tap callback). While the mouse is offline — powered off, asleep, dongle unplugged —
    /// its mappings must not fire: the tap can't tell which device sent a click, so they'd
    /// keep remapping matching buttons on every other pointing device. Published so the
    /// remap UI can say why nothing is firing (button detection still works while paused).
    @Published var remappingPaused = false

    /// Called when a mapped button is pressed while remapping is paused. The mouse is paused
    /// because the app last saw it offline, and a press of one of its mapped buttons is a good
    /// sign it has just woken up. Without this, the mapping only came back at the next battery
    /// poll, and that poll backs off while the mouse is away. Main thread, like the tap.
    var onPressWhilePaused: (() -> Void)?

    /// Switch to the connected mouse's mappings (called when the device changes). `key` is the
    /// per-unit device key (serial/PID).
    func setActiveDevice(_ key: String?, deviceID: Int? = nil) {
        let k = key ?? "none"
        let idChanged = deviceID != nil && deviceID != activeDeviceID
        guard k != activeKey || idChanged else { return }
        activeKey = k
        if deviceID != nil || k == "none" { activeDeviceID = deviceID }
        seenButtons = [] // detected buttons are per-device
        hyperShiftHeld = false
        suppressedTapButtons = []
        // Side buttons that are plain Back/Forward clicks, listed before the first press.
        suggestedButtons = isBasiliskV3XHyperSpeed || hasHardwareButtonLayout ? [3, 4] : []
        loadMappings()
        loadDpiSoftwareAction()
        dpiBridgeBindingConfirmed = false
        dpiBridgeReadRequested = false
        dpiBridgeRestoreAttempted = false
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
        loadDpiSoftwareAction()
        refreshAccessibility(prompt: false)
    }

    /// Re-check the Accessibility grant (call when the window appears / returns to front).
    func refreshAccessibility(prompt: Bool) {
        // An explicit Re-check is the user saying they changed a permission: try the
        // keyboard-capable tap again.
        if prompt { keyboardTapRefused = false }
        // Use the literal key to avoid touching the non-Sendable global CFString symbol.
        let granted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
        accessibilityGranted = granted
        if granted {
            installTapIfNeeded()
        } else {
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
        tapIncludesKeyboard = false
        eventTapAvailable = false
        keyboardCaptureAvailable = false
        bridgeKeyIsDown = false
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
        mappings = withoutUnremappable(new)
        seenButtons.formUnion(new.keys)
        saveMappings()
    }

    // MARK: Onboard (remaps saved in the mouse)

    /// Where each control of the connected mouse has its remap (`OnboardButtons.plan`),
    /// empty for a mouse without a known function table.
    @Published private(set) var onboardPlan: [OnboardButtons.Entry] = []

    /// The id the active mouse's remaps are saved under (`setActiveDevice`), nil with none.
    var activeDeviceKey: String? { activeKey == "none" ? nil : activeKey }

    /// The active mouse's function table, if it has a known one.
    private var onboardLayout: [OnboardButtons.Control]? {
        guard activeKey != "none", let pid = activeDeviceID else { return nil }
        return OnboardButtons.layout(pid: pid)
    }

    /// Whether the connected mouse keeps its remaps itself.
    var mappingsLiveInMouse: Bool { onboardLayout != nil }
    /// The active mouse's remappable controls, for the remap window.
    var onboardControls: Set<Int> { Set(onboardLayout?.map(\.button) ?? []) }
    /// Whether a control is HyperShift from the factory (the side trigger,
    /// `OnboardButtons.isHyperShiftOnFactory`).
    func hyperShiftIsDefault(_ button: Int) -> Bool {
        onboardLayout?.first { $0.button == button }.map(OnboardButtons.isHyperShiftOnFactory) ?? false
    }

    /// The highest DPI the active mouse takes, for the custom DPI Clutch.
    var activeMaxDPI: Int { activeDeviceID.map(RazerDevices.maxDPI(pid:)) ?? 26000 }

    /// Whether an action is what a control already does from the factory, so its menu
    /// needn't offer it (HyperShift on the side trigger, Cycle Scroll Mode on Scroll Mode).
    func isDefault(_ action: RemapAction, for button: Int) -> Bool {
        guard let control = onboardLayout?.first(where: { $0.button == button }) else { return false }
        return OnboardButtons.isFactory(action, on: control)
    }

    /// Whether a control is the HyperShift clutch: set to HyperShift, or left on a factory
    /// HyperShift.
    func isHyperShiftClutch(_ button: Int) -> Bool {
        if let action = mappings[button], action != .passthrough { return action == .hyperShift }
        return hyperShiftIsDefault(button)
    }
    /// Controls whose remap is saved in the mouse: what they send is already the remapped
    /// action, so the tap lets it through untouched.
    private var savedInMouse: Set<Int> = []

    /// Whether any remap needs the event tap, and so the Accessibility permission.
    var needsEventTap: Bool {
        !mappingsLiveInMouse || onboardPlan.contains { $0.placement == .app }
    }

    /// Whether MacRazer sees this control's presses, so it can be given an action only
    /// MacRazer can do (Double Click, HyperShift, a HyperShift mapping). Every button of a
    /// mouse without a function table; on one with, only those that are a mouse button while
    /// on their factory function (`OnboardButtons.appSees`).
    func appSees(_ button: Int) -> Bool {
        guard let control = onboardLayout?.first(where: { $0.button == button }) else { return true }
        return OnboardButtons.appSees(control)
    }

    /// A remap that can't fire: only MacRazer can do it, but it never sees the control.
    func remapCantFire(_ button: Int) -> Bool {
        onboardPlan.contains { $0.control.button == button && $0.placement == .app } && !appSees(button)
    }

    /// The order the remap window lists the active mouse's controls in, empty for none.
    var activeRowOrder: [Int] { onboardLayout == nil ? [] : activeDeviceID.flatMap(OnboardButtons.rowOrder(pid:)) ?? [] }

    private func refreshOnboardPlan() {
        let plan = activeDeviceID.map { OnboardButtons.plan(pid: $0, mappings: activeKey == "none" ? [:] : mappings) } ?? []
        if plan != onboardPlan { onboardPlan = plan }
        savedInMouse = Set(plan.compactMap { entry in
            if case .mouse = entry.placement { return entry.control.button }
            return nil
        })
    }

    // MARK: HyperShift

    /// HyperShift mappings live in `mappings` too, under the button's id plus this offset, so
    /// they are saved, and captured by profiles, with everything else. Button ids run from
    /// -18 (`HardwareButton`) to a few dozen (CGEvent numbers), far from it either way.
    static let hyperShiftOffset = 100_000
    static func hyperShiftKey(_ button: Int) -> Int { button + hyperShiftOffset }
    static func isHyperShiftKey(_ key: Int) -> Bool { key >= hyperShiftOffset / 2 }

    /// A button mapped to `.hyperShift` is held down. Main thread.
    @Published private(set) var hyperShiftHeld = false
    /// Whether any button is the HyperShift key, so the remap window offers the second layer.
    /// A mouse with an onboard HyperShift layer (`OnboardButtons.shiftedPlan`) always has
    /// one: its side trigger.
    var hasHyperShiftKey: Bool { mappingsLiveInMouse || mappings.values.contains(.hyperShift) }
    /// Tap-path buttons whose press was taken over, so their release is swallowed too even
    /// if HyperShift was let go in between and the release alone would map to nothing.
    private var suppressedTapButtons: Set<Int> = []

    /// What a button does right now: its HyperShift mapping while HyperShift is held (when
    /// it has one), otherwise its normal one. Nil means its own default behaviour.
    func activeAction(for button: Int) -> RemapAction? {
        if hyperShiftHeld, mappings[button] != .hyperShift,
           let shifted = mappings[Self.hyperShiftKey(button)], shifted != .passthrough {
            return shifted
        }
        guard let action = mappings[button], action != .passthrough else { return nil }
        return action
    }

    /// What a mapping slot does: its remap, or what the button does without one
    /// (`defaultLabel`).
    func actionLabel(for button: Int) -> String {
        guard let action = mappings[button], action != .passthrough else { return defaultLabel(for: button) }
        return action.label
    }

    /// What a slot does with no remap. A mouse that keeps its remaps runs the control's
    /// factory function on both layers (`OnboardButtons.shiftedPlan`); with the event tap, a
    /// HyperShift slot falls back to the button's standard mapping.
    func defaultLabel(for button: Int) -> String {
        if Self.isHyperShiftKey(button) {
            let standard = button - Self.hyperShiftOffset
            return mappingsLiveInMouse ? defaultLabel(for: standard) : actionLabel(for: standard)
        }
        if let control = onboardLayout?.first(where: { $0.button == button }) { return OnboardButtons.factoryLabel(control) }
        switch button {
        case -1: return "DPI Cycle"
        case 2: return "Middle Click"
        case 3: return "Back"
        case 4: return "Forward"
        default: return "Default"
        }
    }

    /// Whether a slot does something other than its default: a remap that isn't what the
    /// control does from the factory anyway (Left Index set to Cycle Up Profile isn't).
    func isRemapped(_ button: Int) -> Bool {
        guard let action = mappings[button], action != .passthrough else { return false }
        let control = Self.isHyperShiftKey(button) ? button - Self.hyperShiftOffset : button
        if let factory = onboardLayout?.first(where: { $0.button == control })?.factory,
           OnboardButtons.nativeBlock(for: action) == factory { return false }
        return true
    }

    /// Whether the active mouse has a known function table (`OnboardButtons.layout`).
    private var hasHardwareButtonLayout: Bool { onboardLayout != nil }

    /// `label(for:)`, with the active mouse's own names for its side buttons where they're known.
    func displayLabel(for button: Int) -> String {
        if Self.isHyperShiftKey(button) { return "HyperShift + " + displayLabel(for: button - Self.hyperShiftOffset) }
        if hasHardwareButtonLayout {
            switch button {
            case 1: return "Right Click"
            case 2: return "Scroll Click"
            case 3: return "Side Back"
            case 4: return "Side Middle"
            default: break
            }
        }
        return Self.label(for: button)
    }

    /// Friendly, compact label for a raw CGEvent button number.
    static func label(for button: Int) -> String {
        if let hardware = HardwareButton(rawValue: button) { return hardware.label }
        switch button {
        case -1: return "DPI Cycle"
        case 2: return "Wheel Click"
        case 3: return "Back (4)"
        case 4: return "Forward (5)"
        default: return "Button \(button + 1)"
        }
    }

    /// Mock state for the `render-remap` preview command; `pid` previews that mouse's own list.
    func loadPreviewState(pid: Int? = nil) {
        accessibilityGranted = true
        eventTapAvailable = true
        if let pid {
            activeKey = "preview"
            activeDeviceID = pid
        }
        seenButtons = pid == nil ? [2, 3, 4, 5] : []
        mappings = [3: .keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy  ⌘C")]
    }

    // MARK: - Event tap

    private func installTapIfNeeded() {
        guard accessibilityGranted else { return }
        let includeKeyboard = shouldCaptureKeyboard && !keyboardTapRefused
        guard tap == nil || tapIncludesKeyboard != includeKeyboard else {
            if let tap {
                if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
                eventTapAvailable = CGEvent.tapIsEnabled(tap: tap)
                refreshKeyboardCaptureStatus()
            }
            return
        }
        removeTap()
        installTap(includeKeyboard: includeKeyboard)
    }

    /// macOS refused the keyboard-capable tap this session. Cleared by an explicit Re-check
    /// (`refreshAccessibility(prompt: true)`) or a relaunch.
    private var keyboardTapRefused = false

    private var shouldCaptureKeyboard: Bool {
        isBasiliskV3XHyperSpeed && dpiCycleSoftwareAction != nil
    }

    private func installTap(includeKeyboard: Bool) {
        // otherMouse = middle/wheel-click + extra buttons — the only events we remap.
        // Primary left/right clicks are deliberately never tapped.
        let types: [CGEventType] = includeKeyboard
            ? [.otherMouseDown, .otherMouseUp, .keyDown, .keyUp]
            : [.otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // macOS may reject keyboard capture while allowing mouse events. Keep ordinary
            // button remapping available even when the optional F20 bridge cannot run, and
            // remember the refusal: otherwise every state change would tear down the working
            // mouse-only tap to try the keyboard one again.
            if includeKeyboard {
                installTap(includeKeyboard: false)
                // Only a refusal if mouse events still work. When both fail, the cause is
                // something else (Accessibility not effective yet), so try both again later.
                keyboardTapRefused = tap != nil
            }
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = src
        self.tapIncludesKeyboard = includeKeyboard
        eventTapAvailable = true
        refreshKeyboardCaptureStatus()
    }

    static func includesKeyboardEvents(_ mask: CGEventMask) -> Bool {
        let required = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        return mask & required == required
    }

    private func refreshKeyboardCaptureStatus() {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else {
            keyboardCaptureAvailable = false; return
        }
        var entries = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &entries, &count) == .success else {
            keyboardCaptureAvailable = false; return
        }
        keyboardCaptureAvailable = entries.prefix(Int(count)).contains {
            $0.tappingProcess == getpid() && $0.enabled && Self.includesKeyboardEvents($0.eventsOfInterest)
        }
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

    /// Runs on the main run loop (the tap source is scheduled there). Internal rather than
    /// private so tests can hand it synthetic events.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Skip events we ourselves posted (e.g. a remap-to-middle-click re-enters the tap).
        if event.getIntegerValueField(.eventSourceUserData) == Self.magic {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .keyUp {
            return handleDpiBridge(type: type, event: event)
        }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))

        // Only the extra buttons are remappable (the tap is scoped to otherMouse events,
        // but keep the guard as a defensive net).
        guard type == .otherMouseDown || type == .otherMouseUp else {
            return Unmanaged.passUnretained(event)
        }

        // Saved in the mouse: what arrives is already the remapped action (or the button's
        // own job). Remapping it again here would act twice.
        if savedInMouse.contains(button), !suppressedTapButtons.contains(button) {
            if type == .otherMouseDown, lastDetectedButton != button || !seenButtons.contains(button) {
                lastDetectedButton = button
                seenButtons.insert(button)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseUp, suppressedTapButtons.remove(button) != nil {
            if mappings[button] == .hyperShift { hyperShiftHeld = false }
            return nil // its press was taken over, so its release goes too
        }
        if let action = activeAction(for: button) {
            guard remappingPaused else {
                if type == .otherMouseDown {
                    suppressedTapButtons.insert(button)
                    if action == .hyperShift { hyperShiftHeld = true } else { apply(action) }
                }
                return nil // suppress the original button (both down and up)
            }
            // This press still goes through unchanged: the tap can't tell which device sent
            // it, so it may not be our mouse at all. The check brings the mapping back for the
            // next press, a moment later, if it is.
            if type == .otherMouseDown { onPressWhilePaused?() }
        }

        // Unmapped → remember it for the UI, and let it through unchanged.
        if type == .otherMouseDown, lastDetectedButton != button || !seenButtons.contains(button) {
            lastDetectedButton = button
            seenButtons.insert(button)
        }
        return Unmanaged.passUnretained(event)
    }

    private func apply(_ action: RemapAction) {
        if let actionEmitter { actionEmitter(action); return }
        switch action {
        case .passthrough: break
        case .keystroke(let kc, let mods, _): postKeystroke(keyCode: kc, flags: CGEventFlags(rawValue: mods))
        case .mouseButton(let b, _): postMouseClick(b)
        case .doubleClick: postDoubleClick()
        case .mediaKey(let code, _): postMediaKey(code)
        case .hyperShift: break // a modifier: `hyperShiftHeld` is set where its presses arrive
        case .cycleProfile, .turboClick, .turboKey, .dpiClutch, .cycleScrollMode, .scroll, .dpiStage:
            break // the mouse does these itself
        case .disabled: break // the press is swallowed and nothing is sent
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

    // MARK: - DPI Cycle software actions

    /// F20 is reserved only after the connected Basilisk has confirmed the corresponding
    /// onboard assignment. The event tap includes keyboard events only while this model has a
    /// saved software action; ordinary users keep a mouse-only tap.
    func observeDpiCycle(controller: MouseController) {
        dpiObservers.removeAll()
        controller.$deviceKey.combineLatest(controller.$deviceID)
            .combineLatest(controller.$deviceIsBluetooth)
            .combineLatest(controller.$connected)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak controller] state in
                let (((key, deviceID), bluetooth), connected) = state
                guard let self else { return }
                self.setActiveDevice(key, deviceID: deviceID)
                self.remappingPaused = !connected
                self.installTapIfNeeded()
                if !connected {
                    self.dpiBridgeBindingConfirmed = false
                    self.dpiBridgeReadRequested = false
                    self.dpiBridgeRestoreAttempted = false
                } else if bluetooth, deviceID.map(RazerDevices.supportsDpiButtonBinding(pid:)) == true,
                          !self.dpiBridgeReadRequested {
                    self.dpiBridgeReadRequested = true
                    controller?.refreshDpiCycleButtonBinding()
                }
            }.store(in: &dpiObservers)

        controller.$wakeRecoveryCounter
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak controller] _ in
                guard let self, let controller, controller.connected, controller.deviceIsBluetooth,
                      controller.deviceID.map(RazerDevices.supportsDpiButtonBinding(pid:)) == true else { return }
                // A wake can preserve the BLE session, so the connected observer above does
                // not fire. Re-read once in case firmware reset the physical assignment.
                self.dpiBridgeRestoreAttempted = false
                self.dpiBridgeReadRequested = false
                controller.refreshDpiCycleButtonBinding()
            }.store(in: &dpiObservers)

        controller.$dpiCycleButtonBinding
            .combineLatest(controller.$deviceIsBluetooth)
            .combineLatest(controller.$isUpdatingDpiCycleButton)
            .combineLatest(controller.$connected)
            .combineLatest(controller.$dpiCycleButtonError)
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self, weak controller] state in
                let (((bindingState, updating), connected), error) = state
                let (binding, bluetooth) = bindingState
                guard let self else { return }
                self.confirmDpiBridge(binding: bluetooth ? binding : nil)
                guard let controller, connected, bluetooth, self.isBasiliskV3XHyperSpeed,
                      !updating, error == nil,
                      self.shouldRestoreDpiBridge(binding: binding,
                                                  connected: connected,
                                                  bluetooth: bluetooth,
                                                  alreadyAttempted: self.dpiBridgeRestoreAttempted),
                      let action = self.dpiCycleSoftwareAction else { return }
                self.dpiBridgeRestoreAttempted = true
                self.configureDpiCycle(.softwareBridge, softwareAction: action, controller: controller)
            }.store(in: &dpiObservers)
    }

    func confirmDpiBridge(binding: BLEProtocol.DPIButtonBinding?) {
        dpiBridgeBindingConfirmed = isBasiliskV3XHyperSpeed && binding == .softwareBridge
    }

    func shouldRestoreDpiBridge(binding: BLEProtocol.DPIButtonBinding?, connected: Bool,
                                bluetooth: Bool, alreadyAttempted: Bool) -> Bool {
        // `binding` must have been read from the mouse: nil means "not known yet" (after a
        // reconnect), and restoring then would write before the fresh read.
        isBasiliskV3XHyperSpeed && connected && bluetooth && !alreadyAttempted
            && binding != nil && binding != .softwareBridge && dpiCycleSoftwareAction != nil
    }

    func configureDpiCycle(_ binding: BLEProtocol.DPIButtonBinding,
                           softwareAction: RemapAction? = nil, controller: MouseController) {
        guard softwareAction == nil || remappingPermissionsGranted else { return }
        dpiBridgeBindingConfirmed = false
        controller.setDpiCycleButtonBinding(binding) { [weak self] success in
            guard success, let self else { return }
            self.saveDpiSoftwareAction(softwareAction)
            self.confirmDpiBridge(binding: binding)
        }
    }

    func dpiCycleLabel(for binding: BLEProtocol.DPIButtonBinding) -> String {
        if binding == .softwareBridge {
            return dpiCycleSoftwareAction.map { $0.label + " (MacRazer)" } ?? "MacRazer action (choose…)"
        }
        return binding.label
    }

    func saveDpiSoftwareAction(_ action: RemapAction?) {
        guard isBasiliskV3XHyperSpeed else { return }
        let previous = dpiCycleSoftwareAction
        dpiCycleSoftwareAction = action
        let key = "dpiCycleSoftwareAction-\(activeKey)"
        if let action, let data = try? JSONEncoder().encode(action) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        installTapIfNeeded()
        if action != previous { onManualChange?() }
    }

    private func loadDpiSoftwareAction() {
        dpiCycleSoftwareAction = nil
        guard isBasiliskV3XHyperSpeed,
              let data = defaults.data(forKey: "dpiCycleSoftwareAction-\(activeKey)") else { return }
        dpiCycleSoftwareAction = try? JSONDecoder().decode(RemapAction.self, from: data)
    }

    var dpiBridgeStatus: String {
        if !remappingPermissionsGranted { return "Input capture unavailable" }
        if !keyboardCaptureAvailable { return "Keyboard capture is blocked. Refresh Input Monitoring, then relaunch." }
        if remappingPaused { return "Waiting for mouse connection" }
        if !dpiBridgeBindingConfirmed { return "Waiting for button assignment verification" }
        return "Ready"
    }

    private func handleDpiBridge(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.keyboardEventKeycode) == 90 else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp, bridgeKeyIsDown {
            bridgeKeyIsDown = false
            return nil
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard type == .keyDown, isBasiliskV3XHyperSpeed, dpiBridgeBindingConfirmed,
              !remappingPaused, event.flags.intersection(modifiers).isEmpty,
              let action = dpiCycleSoftwareAction else { return Unmanaged.passUnretained(event) }
        if !bridgeKeyIsDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            lastDetectedButton = -1
            apply(action)
        }
        bridgeKeyIsDown = true
        return nil
    }

    // MARK: - Persistence

    private func saveMappings() {
        // No connected device, no persistence: an edit made in a remap window that outlived
        // a disconnect would otherwise be saved under the meaningless "none" key and
        // silently dropped on reconnect.
        guard activeKey != "none" else { return }
        if let data = try? JSONEncoder().encode(mappings) {
            defaults.set(data, forKey: defaultsKey)
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
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Int: RemapAction].self, from: data) else { return }
        let kept = withoutUnremappable(decoded)
        mappings = kept
        seenButtons.formUnion(kept.keys)
        if kept != decoded { saveMappings() }
    }

    /// `mappings` minus remaps the active mouse can't take: on a mouse that keeps its remaps,
    /// its HyperShift layer lives in the mouse, so a HyperShift action has to be one the mouse
    /// can do. A button set to HyperShift is a clutch the mouse keeps itself, on the standard
    /// layer only.
    private func withoutUnremappable(_ table: [Int: RemapAction]) -> [Int: RemapAction] {
        guard onboardLayout != nil else { return table }
        return table.filter { key, action in
            guard Self.isHyperShiftKey(key) else { return true }
            return action == .passthrough || (action != .hyperShift && OnboardButtons.nativeBlock(for: action) != nil)
        }
    }
}

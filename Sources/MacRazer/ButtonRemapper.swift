// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import ApplicationServices
import CoreGraphics
import IOKit.hid

/// What a remapped button does. `.passthrough` lets the original event through; `.keystroke`
/// suppresses the button and posts a key combo instead. `.launchpad` opens Launchpad, which
/// is Apps on macOS 26 (`LaunchpadApp`). `.gesture` makes it a gesture button: held and moved,
/// it fires one action per direction; pressed in place, its click action. `.dpiCycle` steps
/// the DPI stage in software. Only a slot of the DPI button's gesture on a mouse with private
/// keys offers it (`ButtonRemapper.gestureSlotLeadingChoices`), as there the firmware no
/// longer cycles DPI in driver mode; anywhere else it does nothing (`ButtonRemapper.apply`).
/// New cases: everything saved before them decodes as it did.
enum RemapAction: Codable, Equatable, Sendable {
    case passthrough
    case keystroke(keyCode: UInt16, modifiers: UInt64, name: String)
    case mouseButton(button: Int, name: String)
    case doubleClick
    case mediaKey(code: Int, name: String)
    case launchpad
    case dpiCycle
    indirect case gesture(GestureBindings)

    var label: String {
        switch self {
        case .passthrough: return "None"
        case .keystroke(_, _, let name), .mouseButton(_, let name), .mediaKey(_, let name): return name
        case .doubleClick: return "Double Click"
        case .launchpad: return LaunchpadApp.label
        case .dpiCycle: return "DPI Cycle"
        case .gesture: return "Gesture"
        }
    }

    var isGesture: Bool {
        if case .gesture = self { return true }
        return false
    }
}

/// What a gesture button does: one action for a press and release in place, one for a
/// swipe in each direction while it's held, and on the DPI button of a mouse with private
/// keys one for a long press released without a swipe (`hold`). Each is an ordinary
/// `RemapAction`. A gesture inside a gesture is never offered, and does nothing if one ever
/// turns up in saved data (`ButtonRemapper.apply` ignores it).
struct GestureBindings: Codable, Equatable, Sendable {
    var click: RemapAction
    /// What a long press of the DPI button of a mouse with private keys does when it is
    /// released without a swipe (`ButtonRemapper.handlePrivateKey`). None by default. Any
    /// other button has no short and long press, so its press without a swipe is `click`, and
    /// this is never offered there nor fired (`ButtonRemapper.gestureSlots(button:privateKeys:)`).
    var hold: RemapAction = .passthrough
    var up: RemapAction
    var down: RemapAction
    var left: RemapAction
    var right: RemapAction

    private enum CodingKeys: String, CodingKey {
        case click, hold, up, down, left, right
    }

    init(click: RemapAction, hold: RemapAction = .passthrough, up: RemapAction, down: RemapAction,
         left: RemapAction, right: RemapAction) {
        self.click = click
        self.hold = hold
        self.up = up
        self.down = down
        self.left = left
        self.right = right
    }

    /// Everything saved before Hold existed has no `hold` key, and reads as None.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        click = try container.decode(RemapAction.self, forKey: .click)
        hold = try container.decodeIfPresent(RemapAction.self, forKey: .hold) ?? .passthrough
        up = try container.decode(RemapAction.self, forKey: .up)
        down = try container.decode(RemapAction.self, forKey: .down)
        left = try container.decode(RemapAction.self, forKey: .left)
        right = try container.decode(RemapAction.self, forKey: .right)
    }

    /// `hold` is written only when it isn't None, so a gesture without it is saved exactly as
    /// before Hold existed: in the mappings, the DPI button's action and every profile.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(click, forKey: .click)
        if hold != .passthrough { try container.encode(hold, forKey: .hold) }
        try container.encode(up, forKey: .up)
        try container.encode(down, forKey: .down)
        try container.encode(left, forKey: .left)
        try container.encode(right, forKey: .right)
    }

    subscript(slot: GestureSlot) -> RemapAction {
        get {
            switch slot {
            case .click: click
            case .hold: hold
            case .up: up
            case .down: down
            case .left: left
            case .right: right
            }
        }
        set {
            switch slot {
            case .click: click = newValue
            case .hold: hold = newValue
            case .up: up = newValue
            case .down: down = newValue
            case .left: left = newValue
            case .right: right = newValue
            }
        }
    }

    /// The action a swipe in `direction` fires.
    func action(for direction: GestureDirection) -> RemapAction { self[GestureSlot(direction)] }

    /// What choosing Gesture sets, laid out like the gesture button on Logitech's MX mice:
    /// up for Mission Control, down for Launchpad (Apps on macOS 26), and left and right to
    /// change Space the way a trackpad does, as if the hand grabbed the desktop and moved it:
    /// a swipe left brings the next Space (Space Right), a swipe right the previous one (Space
    /// Left). App Exposé, the other natural choice for down, does nothing as a trackpad swipe
    /// while its trackpad gesture is off, which it is out of the box. `click` is what a press
    /// without a swipe does. Hold starts as None. Only new gestures get these: a saved one
    /// keeps its choices, and the two Space slots can be swapped back in the editor.
    static func defaults(click: RemapAction) -> GestureBindings {
        func preset(_ id: String) -> RemapAction {
            ButtonRemapper.presets.first { $0.id == id }?.action ?? .passthrough
        }
        return GestureBindings(click: click, up: preset("missionControl"), down: .launchpad,
                               left: preset("spaceRight"), right: preset("spaceLeft"))
    }

    /// The defaults for a mouse button, whose click keeps doing what the button did before
    /// (`ButtonRemapper.originalClick`). The DPI button has no click of its own, so its click
    /// starts as None on every mouse: DPI Cycle is a choice on a mouse with private keys, but
    /// a new gesture doesn't pick it.
    static func defaults(for button: Int) -> GestureBindings {
        defaults(click: ButtonRemapper.originalClick(for: button))
    }
}

/// One of a gesture's six actions, in the order the gesture editor lists them. The editor
/// shows Hold only where it means something (`ButtonRemapper.gestureSlots(button:privateKeys:)`).
enum GestureSlot: CaseIterable, Sendable {
    case click, hold, up, down, left, right

    init(_ direction: GestureDirection) {
        switch direction {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        }
    }

    var title: String {
        switch self {
        case .click: "Click"
        case .hold: "Hold"
        case .up: "Swipe Up"
        case .down: "Swipe Down"
        case .left: "Swipe Left"
        case .right: "Swipe Right"
        }
    }
}

/// The system app that `RemapAction.launchpad` opens: Launchpad on macOS 15 and earlier, and
/// Apps, which replaced it, on macOS 26 (there is no Launchpad.app there). It has no keyboard
/// shortcut by default, so it is opened by bundle id rather than typed.
enum LaunchpadApp {
    /// Apps, macOS 26 and later (`/System/Applications/Apps.app`).
    static let appsBundleID = "com.apple.apps.launcher"
    /// Launchpad, macOS 15 and earlier.
    static let launchpadBundleID = "com.apple.launchpad.launcher"
    /// Tried in this order: a Mac with Apps has no Launchpad to open.
    static let bundleIDs = [appsBundleID, launchpadBundleID]

    /// The first of `bundleIDs` that `exists` says is installed, or nil for neither.
    static func installedBundleID(exists: (String) -> Bool) -> String? {
        bundleIDs.first(where: exists)
    }

    /// What the menus call it, from the bundle that is installed: "Apps" where Apps is the one
    /// there, the name macOS 26 gives it, and "Launchpad" otherwise.
    static func label(installed bundleID: String?) -> String {
        bundleID == appsBundleID ? "Apps" : "Launchpad"
    }

    /// This Mac's app, looked up once: it can't change while the app runs.
    static let installed: String? = installedBundleID { url(of: $0) != nil }

    static let label = label(installed: installed)

    private static func url(of bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Opens it, or does nothing on a Mac with neither.
    static func open() {
        guard let installed, let url = url(of: installed) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
    @Published private(set) var eventTapAvailable = false
    @Published private(set) var keyboardCaptureAvailable = false
    @Published private(set) var lastDetectedButton: Int?
    @Published private(set) var seenButtons: Set<Int> = []
    @Published private(set) var suggestedButtons: Set<Int> = []
    @Published private(set) var mappings: [Int: RemapAction] = [:]
    /// Other apps with an event tap that can swallow extra-button clicks (Synapse, Mac Mouse
    /// Fix, …). One that gets a click first leaves nothing for ours to see, so the page names
    /// them. Refreshed with the Accessibility check.
    @Published private(set) var competingTapApps: [String] = []
    /// A button past the wheel click has reached our tap from this mouse. Then nothing is
    /// taking its clicks, and naming apps that could would only be noise.
    @Published private(set) var sideButtonDetected = false
    /// Whether to show `competingTapApps`. A filtering tap may still pass every click on, so
    /// the apps are named only while no side button has got through.
    var showsCompetingApps: Bool { !competingTapApps.isEmpty && !sideButtonDetected }
    private var workspaceObservers: [NSObjectProtocol] = []

    /// What MacRazer does with the DPI button, saved per device: on F20 (the Basilisk V3 X), or
    /// on its private keys in driver mode (`supportsDpiPrivateKeys`). Set only once the mouse
    /// has read back the assignment that goes with it (`configureDpiCycle`), or by editing the
    /// gesture it already is (`setGestureAction(_:for:of:)` with `dpiButton`).
    @Published private(set) var dpiCycleSoftwareAction: RemapAction?
    /// The mouse was read holding the F20 assignment. Until then F20 goes through untouched.
    @Published private(set) var dpiBridgeBindingConfirmed = false
    /// Where the DPI button's driver mode stands, as `MouseController` last published it
    /// (`dpiDriverModeChanged`), on a mouse with private keys. Its keys count only while it is
    /// `.engaged` (`privateKeysActive`).
    @Published private(set) var dpiDriverMode: DpiDriverModeState = .off
    /// The DPI button's private keys couldn't be watched: the mouse's HID device wouldn't open
    /// while Input Monitoring reads as granted, which macOS sometimes applies to a running app
    /// only once it is reopened. Driver mode isn't wanted then (`DpiDriverModeNeed.relaunch`),
    /// so the button keeps cycling DPI rather than doing nothing. Not for the whole run: it is
    /// dropped when Input Monitoring reads as not granted (a grant after that is tried afresh),
    /// and whenever the permissions are looked at again and the device opens
    /// (`retryBlockedPrivateKeys`).
    @Published private(set) var privateKeyInputBlocked = false
    /// Driver mode for the DPI button waits only for a permission (`DpiDriverModeNeed.waitsForPermission`)
    /// while the mouse is connected, and so the permissions are looked at every
    /// `permissionRecheckInterval` (`permissionRecheckTimer`).
    @Published private(set) var waitsForPermission = false
    /// The DPI button's F20 press was swallowed and its release hasn't come yet
    /// (`handleDpiBridge`). Kept across a reinstall of a tap that still sees the keys
    /// (`tapReplaced`).
    private var bridgeKeyIsDown = false
    /// Mouse buttons whose press the tap swallowed and whose release hasn't come yet: the
    /// release is swallowed exactly when its press was (`handle`), as F20's is
    /// (`bridgeKeyIsDown`). Kept across a reinstall of the tap; a fresh press of the button
    /// starts over either way, and none is left once no tap is coming back.
    private var swallowedPresses: Set<Int> = []
    private var dpiBridgeReadRequested = false
    private var dpiBridgeRestoreAttempted = false
    private var dpiObservers = Set<AnyCancellable>()
    private let defaults: UserDefaults
    private let actionEmitter: ((RemapAction) -> Void)?
    /// Where a gesture's system swipes go as they follow the pointer (`DockSwipeTracker`).
    /// Nil leaves them keyboard shortcuts that fire once, as every other slot's action does.
    private let dockSwipes: DockSwipeOutput?
    /// Where `systemSwipesFollowPointer` is saved: one setting for the app, not per device,
    /// and not part of a profile.
    static let systemSwipesFollowPointerKey = "gestureSystemSwipesFollowPointer"
    /// Whether a gesture's four system presets (Mission Control, App Exposé and the Spaces)
    /// follow the pointer as dock swipes where this Mac takes them (`dockSwipes`). On unless
    /// turned off in the gesture editor. Off, a hold is exactly what it is on a Mac without
    /// dock swipes: no tracker, and each preset is the keyboard shortcut its slot holds, fired
    /// once at 50 points, for a mouse button's hold and the DPI button's alike. Holds read it
    /// as they start (`dockSwipeTracker(for:)`), so a change ends the one in progress, which
    /// cancels its open swipe (`gestureHold`): the Dock never stays halfway, and no hold goes
    /// on the other way from how it began.
    @Published var systemSwipesFollowPointer: Bool {
        didSet {
            guard systemSwipesFollowPointer != oldValue else { return }
            defaults.set(systemSwipesFollowPointer, forKey: Self.systemSwipesFollowPointerKey)
            GestureDebugLog.log("SWIPE follow the pointer \(systemSwipesFollowPointer ? "on" : "off")"
                + (gestureHold.map { ", ending the hold of trigger=\($0.trigger)" } ?? ""))
            gestureHold = nil
        }
    }
    /// A new hold's system swipes follow the pointer: this Mac takes dock swipes, and
    /// `systemSwipesFollowPointer` is on. What the gesture editor's explanation goes by.
    var systemSwipesFollowPointerHere: Bool { dockSwipes != nil && systemSwipesFollowPointer }
    /// Seconds on a monotonic clock, for a swipe's velocity. Tests pass their own.
    private let clock: () -> TimeInterval
    /// Where the DPI button's private keys come from while its driver mode is engaged
    /// (`DpiPrivateKeyWatcher`). Nil: nothing watches the mouse, and the keys come only from
    /// whoever calls `handlePrivateKey`, as tests do.
    private let privateKeySource: PrivateKeySource?
    /// Whether `waitsForPermission` runs a timer. Only for a remapper whose actions are posted
    /// for real: a test's would look at the real Accessibility grant, and could install a real
    /// event tap, from a timer. A test reads `waitsForPermission` instead.
    private let schedulesPermissionRechecks: Bool

    /// `dockSwipes`: by default the session's own (`DockSwipeOutput.system`), but only when
    /// actions are posted for real too. A test that catches the actions (`actionEmitter`)
    /// never reaches the session: it passes its own recorder, or has no swipes follow the
    /// pointer. `privateKeys` likewise: the mouse's own by default, none for such a test.
    init(defaults: UserDefaults = .standard, actionEmitter: ((RemapAction) -> Void)? = nil,
         dockSwipes: DockSwipeOutput? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         privateKeys: PrivateKeySource? = nil) {
        self.defaults = defaults
        self.actionEmitter = actionEmitter
        self.dockSwipes = dockSwipes ?? (actionEmitter == nil ? .system(userData: Self.magic) : nil)
        // Never written until first changed, and on out of the box.
        self.systemSwipesFollowPointer = defaults.object(forKey: Self.systemSwipesFollowPointerKey) as? Bool ?? true
        self.clock = clock
        self.privateKeySource = privateKeys ?? (actionEmitter == nil ? DpiPrivateKeyWatcher() : nil)
        self.schedulesPermissionRechecks = actionEmitter == nil
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The events the installed tap asks for (`eventMask`), 0 with no tap. A change in what
    /// it should ask for reinstalls it.
    private var tapMask: CGEventMask = 0

    /// A gesture button being held: which one, the movement so far and what it fires.
    struct GestureHold: Equatable {
        /// The CGEvent button number that started it. `dpiButton` (-1) for a hold of the DPI
        /// button, which comes as its long private key instead of a mouse button.
        let trigger: Int
        let bindings: GestureBindings
        var recognizer = GestureRecognizer()
        /// The swipe that follows the pointer when the hold heads for a system swipe. Nil when
        /// none of its directions is one, or system swipes don't follow the pointer here
        /// (`dockSwipes`, `systemSwipesFollowPointer`): the hold is then only `recognizer`'s.
        var swipe: DockSwipeTracker? = nil
        /// The slot a release without a swipe fires: the click, for a mouse button. The long
        /// private key comes only once the button has been held a second, so its short press
        /// is the click and a long press released in place is `.hold`.
        var releaseSlot: GestureSlot = .click
    }
    /// The hold in progress, if any. One at a time: a new press ends it.
    ///
    /// Whatever ends or replaces a hold cancels its dock swipe here, so every reset that sets
    /// this to nil (the tap switched off or removed, a device change, pausing, waking, the
    /// DPI button's driver mode lost, the mapping changing, another button's press) does too,
    /// and the Dock is never left halfway. Nothing fires for such a reset. The end that
    /// finishes a swipe sends its own first (`endGesture`). Cheap enough for the pointer's
    /// rate: a hold mutated in place goes by a nil check.
    private(set) var gestureHold: GestureHold? {
        didSet {
            if openDockSwipe != nil, gestureHold?.swipe?.isSwiping != true { cancelOpenDockSwipe() }
        }
    }
    /// The last frame posted of a dock swipe that hasn't ended: what a reset cancels.
    private var openDockSwipe: DockSwipe.Frame?
    /// Pointer events fed to the hold in progress, for `GestureDebugLog` only.
    private var debugMoveCount = 0
    /// Per-device key so each mouse keeps its own remaps.
    private var activeKey = "none"
    private var activeDeviceID: Int?
    /// The DPI button's number wherever buttons are numbered: `label(for:)`, a gesture hold's
    /// trigger, and `gestureBindings(for:)`. It has no CGEvent button number of its own.
    static let dpiButton = -1
    /// The connected mouse's DPI button can be rebound over Bluetooth
    /// (`RazerDevices.supportsDpiButtonBinding`), and so may carry out an action of MacRazer's.
    var supportsDpiButtonBinding: Bool {
        activeKey != "none" && (activeDeviceID.map(RazerDevices.supportsDpiButtonBinding(pid:)) ?? false)
    }
    /// The connected mouse's DPI button keys in driver mode (`RazerDevices.dpiButtonPrivateKeys`).
    /// Such a mouse's actions go through them, never F20: no key events are tapped for it.
    var dpiPrivateKeys: DpiButtonPrivateKeys? {
        guard supportsDpiButtonBinding else { return nil }
        return activeDeviceID.flatMap(RazerDevices.dpiButtonPrivateKeys(pid:))
    }
    var supportsDpiPrivateKeys: Bool { dpiPrivateKeys != nil }
    /// The DPI button types F20 for MacRazer's actions, exactly as before private keys: a mouse
    /// that can bind it, but has no private keys (the Basilisk V3 X).
    private var usesDpiBridge: Bool { supportsDpiButtonBinding && !supportsDpiPrivateKeys }
    /// The connected mouse has the Basilisk V3 X's Multi-function trigger, for the page's note.
    var hasMultiFunctionTrigger: Bool {
        activeKey != "none" && (activeDeviceID.map(RazerDevices.hasMultiFunctionTrigger(pid:)) ?? false)
    }
    var remappingPermissionsGranted: Bool { accessibilityGranted && eventTapAvailable }
    private var defaultsKey: String { "buttonMappings-\(activeKey)" }
    /// Mirrors `MouseController.connected` (wired in AppDelegate; main-thread, same as the
    /// tap callback). While the mouse is offline — powered off, asleep, dongle unplugged —
    /// its mappings must not fire: the tap can't tell which device sent a click, so they'd
    /// keep remapping matching buttons on every other pointing device. Published so the
    /// remap UI can say why nothing is firing (button detection still works while paused).
    /// Pausing ends a gesture hold: its release fires nothing, and is still swallowed as its
    /// press was.
    @Published var remappingPaused = false {
        didSet {
            if remappingPaused { gestureHold = nil }
            // Waiting for a permission is pointless while the mouse is away.
            if remappingPaused != oldValue { updatePermissionRecheck() }
        }
    }

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
        sideButtonDetected = false
        suggestedButtons = supportsDpiButtonBinding ? [3, 4] : []
        gestureHold = nil
        loadMappings()
        loadDpiSoftwareAction()
        dpiBridgeBindingConfirmed = false
        dpiBridgeReadRequested = false
        dpiBridgeRestoreAttempted = false
        // The private keys being watched were the last mouse's.
        syncPrivateKeySource()
        // This mouse's mappings may have gestures where the last one's had none, or none
        // where it had some: the drags are asked for only while one needs them. Whether this
        // one needs driver mode is worked out there too (`refreshDpiDriverModeWant`).
        installTapIfNeeded()
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
        .init(id: "missionControl", name: "Mission Control  ⌃↑", keyCode: 126,
              flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]),
        .init(id: "appExpose", name: "App Exposé  ⌃↓", keyCode: 125,
              flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]),
        .init(id: "spaceLeft", name: "Space Left  ⌃←", keyCode: 123,
              flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]),
        .init(id: "spaceRight", name: "Space Right  ⌃→", keyCode: 124,
              flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]),
        .init(id: "screenshot", name: "Screenshot  ⇧⌘4", keyCode: 21, flags: [.maskCommand, .maskShift]),
        .init(id: "switchApp", name: "Switch App  ⌘Tab", keyCode: 48, flags: .maskCommand),
    ]

    /// The preset the menus list Launchpad (`RemapAction.launchpad`) after: the last of the
    /// system ones, Mission Control, App Exposé and the Spaces.
    static let launchpadMenuAnchor = "spaceRight"

    // MARK: - Lifecycle

    func start() {
        GestureDebugHIDWatch.startIfEnabled()
        loadMappings()
        loadDpiSoftwareAction()
        refreshAccessibility(prompt: false)
        // Keep the named apps current while the page is open: quitting one is what the note
        // asks for. A launched app may create its tap a moment after it starts.
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.refreshCompetingTaps()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refreshCompetingTaps() }
        })
        // No hold lasts through the Mac's sleep: a release that came while it slept was never
        // seen, and the hold would turn the first movement after waking into a swipe.
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.cancelGesture()
        })
    }

    /// Re-check the Accessibility grant (call when the window appears / returns to front, the
    /// popover opens, and every `permissionRecheckInterval` while `waitsForPermission`). Input
    /// Monitoring is looked at too, for the DPI button's driver mode (`refreshDpiDriverModeWant`).
    func refreshAccessibility(prompt: Bool) {
        guard !RenderOptions.isActive else { return }
        // An explicit Re-check is the user saying they changed a permission: try the
        // keyboard-capable tap again.
        if prompt { keyboardTapRefused = false }
        // Whatever brought us here, a run that couldn't watch the DPI button's keys may now.
        retryBlockedPrivateKeys()
        defer { refreshDpiDriverModeWant() }
        // Use the literal key to avoid touching the non-Sendable global CFString symbol.
        let granted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
        accessibilityGranted = granted
        if granted {
            installTapIfNeeded()
        } else {
            removeTap()
            // No tap is coming back to see these presses' releases.
            bridgeKeyIsDown = false
            swallowedPresses = []
        }
        refreshCompetingTaps()
    }

    /// Tears down the event tap and its run-loop source — called when Accessibility is revoked
    /// while the app is running, so a stale tap isn't left registered indefinitely, and before
    /// a tap with another mask is installed. Ends any hold, the DPI button's too: its events
    /// may go by unseen in between. `bridgeKeyIsDown` and `swallowedPresses` stay, so the
    /// release of a swallowed press that reaches the new tap is still swallowed (`tapReplaced`).
    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        tapMask = 0
        gestureHold = nil
        eventTapAvailable = false
        keyboardCaptureAvailable = false
    }

    /// What carries over to the tap that replaced the old one, which asks for `mask` (0 when
    /// none could be installed). Adding the first gesture or removing the last reinstalls the
    /// tap, and the DPI button may be held right then: its F20 release must still be
    /// swallowed, as its press was. A tap without the keys never sees that release, though, so
    /// it is forgotten; a later tap with them would otherwise swallow the release of a press an
    /// app saw. Internal rather than private so tests can follow a reinstall without installing
    /// a real tap.
    func tapReplaced(mask: CGEventMask) {
        if !Self.includesKeyboardEvents(mask) { bridgeKeyIsDown = false }
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
        // A hold of this button was started with what it did before.
        if gestureHold?.trigger == button { gestureHold = nil }
        mappings[button] = action
        seenButtons.insert(button)
        saveMappings()
        installTapIfNeeded()
        onManualChange?()
    }

    /// Replaces the whole mapping table at once — used when applying a saved profile (as opposed
    /// to a single-button edit from the remap UI, which goes through `setAction`).
    func setMappings(_ new: [Int: RemapAction]) {
        gestureHold = nil
        mappings = new
        seenButtons.formUnion(new.keys)
        saveMappings()
        installTapIfNeeded()
    }

    /// What choosing Gesture… for a button does: the defaults (`GestureBindings.defaults`)
    /// when it isn't a gesture yet. One that already is keeps its choices, as choosing it
    /// again is how the editor is reopened.
    /// Not for the DPI button, whose gesture needs driver mode (`makeDpiGesture`).
    func makeGesture(_ button: Int) {
        guard button != Self.dpiButton, mappings[button]?.isGesture != true else { return }
        setAction(.gesture(.defaults(for: button)), for: button)
    }

    /// A gesture button's actions, or nil when the button isn't one. `dpiButton` reads
    /// the DPI button's software action, so the gesture editor serves it as any other.
    func gestureBindings(for button: Int) -> GestureBindings? {
        let action = button == Self.dpiButton ? dpiCycleSoftwareAction : mappings[button]
        guard case .gesture(let bindings) = action else { return nil }
        return bindings
    }

    /// Sets one of a gesture button's actions. Nothing changes for a button that isn't a
    /// gesture, or for a gesture as the action: one nested in another would never fire.
    /// For the DPI button only the saved action changes: its entry already holds DPI Cycle
    /// under driver mode, so nothing is written to it.
    func setGestureAction(_ action: RemapAction, for slot: GestureSlot, of button: Int) {
        guard var bindings = gestureBindings(for: button), !action.isGesture else { return }
        bindings[slot] = action
        if button == Self.dpiButton {
            saveDpiSoftwareAction(.gesture(bindings))
        } else {
            setAction(.gesture(bindings), for: button)
        }
    }

    func actionLabel(for button: Int) -> String { mappings[button]?.label ?? "None" }

    /// A click of `button` itself. A gesture's click re-posts it, so a press without a swipe
    /// still does what the button did before: the wheel click still opens a link in a new
    /// tab, Back still goes back. `.passthrough` (nothing) for the DPI button (`dpiButton`)
    /// and the primary buttons, which have no click of their own to post: a new DPI gesture's
    /// click does nothing until one is chosen, DPI Cycle among the choices on a mouse with
    /// private keys (`gestureSlotLeadingChoices`).
    static func originalClick(for button: Int) -> RemapAction {
        let name: String
        switch button {
        case ..<2: return .passthrough
        case 2: name = "Middle Click"
        case 3: name = "Back Button"
        case 4: name = "Forward Button"
        default: name = "Button \(button + 1)"
        }
        return .mouseButton(button: button, name: name)
    }

    /// Friendly, compact label for a raw CGEvent button number.
    static func label(for button: Int) -> String {
        switch button {
        case dpiButton: return "DPI Button"
        case 2: return "Wheel Click"
        case 3: return "Back (4)"
        case 4: return "Forward (5)"
        default: return "Button \(button + 1)"
        }
    }

    /// Mock state for the `render-remap` preview command. `gesture` adds a gesture on button
    /// 6 (5), for `render-remap gesture`; the other previews and screenshots keep two remaps.
    func loadPreviewState(gesture: Bool = false) {
        accessibilityGranted = true
        eventTapAvailable = true
        seenButtons = [2, 3, 4, 5]
        mappings = [3: .keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy  ⌘C"),
                    4: .keystroke(keyCode: 9, modifiers: CGEventFlags.maskCommand.rawValue, name: "Paste  ⌘V")]
        if gesture { mappings[5] = .gesture(.defaults(for: 5)) }
    }

    // MARK: - Event tap

    /// Also where whether the DPI button needs driver mode is worked out again: everything
    /// that changes it (the device, its action, the tap) comes through here.
    private func installTapIfNeeded() {
        defer { refreshDpiDriverModeWant() }
        guard accessibilityGranted else { return }
        let mask = wantedEventMask
        guard tap == nil || tapMask != mask else {
            if let tap {
                if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
                eventTapAvailable = CGEvent.tapIsEnabled(tap: tap)
                refreshKeyboardCaptureStatus()
            }
            return
        }
        removeTap()
        installTap(mask: mask)
        // The mask it got, which lacks the keys when macOS refused them.
        tapReplaced(mask: tapMask)
    }

    /// The mask the tap should have now (`eventMask`). A change reinstalls it. Internal rather
    /// than private so tests can check what the mappings and the DPI button's action ask for.
    var wantedEventMask: CGEventMask {
        Self.eventMask(keyboard: shouldCaptureKeyboard && !keyboardTapRefused, gestures: wantsGestureEvents,
                       privateKeyGesture: wantsPrivateKeyGestureEvents)
    }

    /// A gesture needs the pointer's movement while its button is held.
    private var wantsGestureEvents: Bool {
        mappings.values.contains { $0.isGesture }
    }

    /// The DPI button is a gesture held through its long private key: no mouse button is down,
    /// so its movement comes as plain pointer moves, and no key is involved.
    private var wantsPrivateKeyGestureEvents: Bool {
        supportsDpiPrivateKeys && dpiCycleSoftwareAction?.isGesture == true
    }

    /// macOS refused the keyboard-capable tap this session. Cleared by an explicit Re-check
    /// (`refreshAccessibility(prompt: true)`) or a relaunch.
    private var keyboardTapRefused = false

    /// The F20 bridge needs the keys. A mouse with private keys never does, so its tap never
    /// sees what a keyboard types.
    private var shouldCaptureKeyboard: Bool {
        usesDpiBridge && dpiCycleSoftwareAction != nil
    }

    private func installTap(mask: CGEventMask) {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // macOS may reject keyboard capture while allowing mouse events. Keep ordinary
            // button remapping available even when the optional F20 bridge cannot run, and
            // remember the refusal: otherwise every state change would tear down the working
            // mouse-only tap to try the keyboard one again.
            if Self.includesKeyboardEvents(mask) {
                // The same mask without the keys, so gestures keep their drags and the next
                // `installTapIfNeeded` finds the mask it asks for.
                installTap(mask: mask & ~Self.keyboardEventsMask)
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
        self.tapMask = mask
        eventTapAvailable = true
        refreshKeyboardCaptureStatus()
    }

    /// The events the tap asks for. otherMouse = middle/wheel-click + extra buttons, the only
    /// buttons we remap; primary left/right clicks are deliberately never tapped. Their drags
    /// only while a gesture needs them: they come at the mouse's polling rate, and a tap that
    /// doesn't ask for them never sees them. Keys only for the DPI button's F20 bridge.
    ///
    /// `privateKeyGesture`: the DPI button is a gesture held through its long private key.
    /// No mouse button is down then, so its movement comes as `.mouseMoved`, asked for only
    /// then and never with any keys: every move of the pointer goes through the tap while it's
    /// in the mask. Primary drags are never asked for, so a DPI hold sees no movement while the
    /// left or right button is also held: that movement is a drag the app under the pointer is
    /// doing.
    static func eventMask(keyboard: Bool, gestures: Bool, privateKeyGesture: Bool = false) -> CGEventMask {
        var types: [CGEventType] = [.otherMouseDown, .otherMouseUp]
        if gestures { types.append(.otherMouseDragged) }
        if privateKeyGesture { types.append(.mouseMoved) }
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        return keyboard ? mask | keyboardEventsMask : mask
    }

    static let keyboardEventsMask: CGEventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
        | (CGEventMask(1) << CGEventType.keyUp.rawValue)

    static func includesKeyboardEvents(_ mask: CGEventMask) -> Bool {
        mask & keyboardEventsMask == keyboardEventsMask
    }

    /// Every event tap on the session, or nil when macOS won't list them.
    private static func eventTaps() -> [CGEventTapInformation]? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return nil }
        var entries = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &entries, &count) == .success else { return nil }
        return Array(entries.prefix(Int(count)))
    }

    private func refreshKeyboardCaptureStatus() {
        keyboardCaptureAvailable = Self.eventTaps()?.contains {
            $0.tappingProcess == getpid() && $0.enabled && Self.includesKeyboardEvents($0.eventsOfInterest)
        } ?? false
    }

    /// What `competingTapPIDs` needs from a `CGEventTapInformation`.
    struct TapEntry: Equatable {
        let pid: pid_t
        /// 0 for a tap on the whole session; else the one app it filters, which can't take
        /// clicks meant for anywhere else.
        let tappedPID: pid_t
        let enabled: Bool
        let listenOnly: Bool
        let eventsOfInterest: CGEventMask
    }

    /// The other processes whose taps can drop an extra-button click before ours sees it:
    /// enabled, session-wide, filtering (a listen-only tap can't drop anything) and asking
    /// for `otherMouseDown`. In list order, each once.
    static func competingTapPIDs(_ taps: [TapEntry], ownPID: pid_t) -> [pid_t] {
        let otherMouse = CGEventMask(1) << CGEventType.otherMouseDown.rawValue
        var seen = Set<pid_t>()
        return taps.compactMap { tap in
            guard tap.pid != ownPID, tap.tappedPID == 0, tap.enabled, !tap.listenOnly,
                  tap.eventsOfInterest & otherMouse != 0, seen.insert(tap.pid).inserted else { return nil }
            return tap.pid
        }
    }

    private func refreshCompetingTaps() {
        let names = Self.currentCompetingTapApps()
        if names != competingTapApps { competingTapApps = names }
    }

    /// The apps whose taps compete with ours (`competingTapPIDs`), each once. Also what the
    /// device test reports (`RemapSoftware`).
    static func currentCompetingTapApps() -> [String] {
        let taps = (eventTaps() ?? []).map {
            TapEntry(pid: $0.tappingProcess, tappedPID: $0.processBeingTapped, enabled: $0.enabled,
                     listenOnly: $0.options == .listenOnly, eventsOfInterest: $0.eventsOfInterest)
        }
        // Apps only: macOS's own daemons tap mouse events too, and passing clicks on is their job.
        var names: [String] = []
        for pid in competingTapPIDs(taps, ownPID: getpid()) {
            guard let name = appName(pid: pid), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    /// The app a process belongs to, or nil for one of macOS's own. A helper launched by
    /// launchd has no `NSRunningApplication`, so the `.app` around its executable names it.
    static func appName(pid: pid_t) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
            return bundleID.hasPrefix("com.apple.") ? nil : app.localizedName ?? bundleID
        }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return appName(executablePath: String(cString: buffer))
    }

    /// The outermost `.app` in the path, without its extension; nil outside one, in macOS's
    /// own folders, or inside one of Apple's apps (an Xcode helper is Apple's, not Xcode the
    /// competitor).
    static func appName(executablePath path: String) -> String? {
        guard !path.hasPrefix("/System/"), !path.hasPrefix("/usr/") else { return nil }
        let components = path.split(separator: "/")
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let appPath = "/" + components[...index].joined(separator: "/")
        if Bundle(path: appPath)?.bundleIdentifier?.hasPrefix("com.apple.") ?? false { return nil }
        return String(components[index].dropLast(4))
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let remapper = Unmanaged<ButtonRemapper>.fromOpaque(userInfo).takeUnretainedValue()
        return remapper.handle(type: type, event: event)
    }

    private static let magic: Int64 = 0x52415A45 // "RAZE" — marks events we post, to skip them
    /// Internal rather than private so tests can check the events it makes carry `magic`.
    lazy var postSource: CGEventSource? = {
        let s = CGEventSource(stateID: .combinedSessionState)
        s?.userData = Self.magic
        return s
    }()

    /// Runs on the main run loop (the tap source is scheduled there). Internal rather than
    /// private so tests can hand it synthetic events.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            GestureDebugLog.log("TAP DISABLED type=\(type.rawValue)")
            // Events went by unseen, perhaps the release that would have ended a hold.
            gestureHold = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // First and short: drags come at the mouse's polling rate, on the main thread, and
        // with no gesture held there is nothing to look at.
        if type == .otherMouseDragged {
            guard gestureHold != nil else { return Unmanaged.passUnretained(event) }
            return handleGestureDrag(event)
        }
        // As short: every move of the pointer comes here while the DPI button is a gesture on a
        // mouse with private keys.
        if type == .mouseMoved {
            if gestureHold?.trigger == Self.dpiButton { handleDpiGestureMove(event) }
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
        if type == .otherMouseDown, button >= 3, !sideButtonDetected { sideButtonDetected = true }

        // Only the extra buttons are remappable (the tap is scoped to otherMouse events,
        // but keep the guard as a defensive net).
        guard type == .otherMouseDown || type == .otherMouseUp else {
            return Unmanaged.passUnretained(event)
        }
        // A release goes the way its press went, whatever changed in between (paused or
        // unpaused, remapped, the hold ended): swallowed after a swallowed press, ending that
        // button's hold (its click, if no swipe fired), and through otherwise. An app must
        // never see a press without its release, which leaves the button held down there.
        if type == .otherMouseUp {
            guard swallowedPresses.remove(button) != nil else { return Unmanaged.passUnretained(event) }
            endGesture(trigger: button)
            return nil
        }
        // A press while a gesture is held ends the hold, so one whose release went missing
        // can't linger and swallow the next drags.
        gestureHold = nil
        swallowedPresses.remove(button)

        if let action = mappings[button], action != .passthrough {
            guard remappingPaused else {
                if case .gesture(let bindings) = action {
                    beginGesture(bindings, trigger: button)
                } else {
                    apply(action)
                }
                swallowedPresses.insert(button)
                return nil // suppress the original button (its release follows, above)
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

    // MARK: - Gestures

    /// A drag while a hold is in progress. Its button must be the one held: the drags of
    /// another button held alongside are that button's, and go through.
    private func handleGestureDrag(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        // Read as doubles, which keeps any fraction of a point macOS reports: a slow, steady
        // swipe would otherwise lose it on every event.
        let moved = moveGesture(dx: event.getDoubleValueField(.mouseEventDeltaX),
                                dy: event.getDoubleValueField(.mouseEventDeltaY), trigger: button)
        // Swallowed while held, as the press was: an app that never saw the button go down
        // shouldn't see it drag. The cursor still moves, so the swipe stays visible.
        return moved ? nil : Unmanaged.passUnretained(event)
    }

    /// A pointer move while the DPI button is held. Unlike a drag it always goes through: no
    /// app saw a button go down, so to them it's a plain move, and swallowing it would only
    /// leave hover effects behind the pointer.
    private func handleDpiGestureMove(_ event: CGEvent) {
        moveGesture(dx: event.getDoubleValueField(.mouseEventDeltaX),
                    dy: event.getDoubleValueField(.mouseEventDeltaY), trigger: Self.dpiButton)
    }

    // The hold itself, apart from the events that drive it, so a trigger other than a mouse
    // button can use it: the DPI button arrives as its long private key down and up
    // (`handlePrivateKey`), its movement as `.mouseMoved` (`handleDpiGestureMove`). Internal
    // so tests can drive a hold directly. `trigger` names the hold as in `GestureHold.trigger`.

    /// A gesture button went down: start a hold, replacing any other. `releaseSlot`: what a
    /// release without a swipe fires (`GestureHold.releaseSlot`).
    func beginGesture(_ bindings: GestureBindings, trigger: Int, releaseSlot: GestureSlot = .click) {
        if GestureDebugLog.enabled {
            GestureDebugLog.log("begin trigger=\(trigger) release=\(releaseSlot.title) replacing=\(gestureHold.map { String($0.trigger) } ?? "none")")
            debugMoveCount = 0
        }
        gestureHold = GestureHold(trigger: trigger, bindings: bindings, swipe: dockSwipeTracker(for: bindings),
                                  releaseSlot: releaseSlot)
    }

    /// The tracker for a hold of `bindings`: nil when no direction holds a system swipe, or
    /// they don't follow the pointer here (no `dockSwipes`, or `systemSwipesFollowPointer`
    /// off). The scale is the screen's as the hold starts.
    ///
    /// App Exposé is a swipe only while the Dock's trackpad gesture for it is on: off, which it
    /// is out of the box, the Dock ignores the swipe and nothing at all would happen. So then it
    /// stays out of the tracker and is the ⌃↓ shortcut its slot holds, fired once at 50 points
    /// like any other action. Asked at every hold, so a change in System Settings counts from
    /// the next press.
    private func dockSwipeTracker(for bindings: GestureBindings) -> DockSwipeTracker? {
        guard let dockSwipes, systemSwipesFollowPointer else { return nil }
        var slots = SystemSwipeSlots(bindings)
        if slots.contains(.appExpose), !dockSwipes.appExposeEnabled() { slots = slots.removing(.appExpose) }
        guard !slots.isEmpty else { return nil }
        return DockSwipeTracker(slots: slots, scale: dockSwipes.scale(), at: clock())
    }

    /// The pointer moved by (dx, dy), CGEvent deltas with y growing downward. When the hold
    /// heads for a system swipe, the swipe follows it (`DockSwipeTracker`); otherwise this
    /// fires the direction's action the first time the hold's movement is far enough.
    /// Returns whether a hold of `trigger` is in progress, and so whether the movement
    /// belongs to it.
    @discardableResult
    func moveGesture(dx: Double, dy: Double, trigger: Int) -> Bool {
        guard gestureHold?.trigger == trigger else { return false }
        if GestureDebugLog.enabled {
            debugMoveCount += 1
            if debugMoveCount <= 5 { GestureDebugLog.log("move #\(debugMoveCount) dx=\(dx) dy=\(dy)") }
        }
        if gestureHold?.swipe != nil, moveDockSwipe(dx: dx, dy: dy) { return true }
        // Mutated in place: a copy of the hold per event would be wasted work at this rate.
        if let direction = gestureHold?.recognizer.move(dx: dx, dy: dy), let hold = gestureHold {
            GestureDebugLog.log("FIRE \(direction) after \(debugMoveCount) moves net=(\(hold.recognizer.dx), \(hold.recognizer.dy)) action=\(hold.bindings.action(for: direction).label)")
            perform(hold.bindings.action(for: direction), trigger: trigger)
        }
        return true
    }

    /// Feeds a movement to the hold's dock swipe and posts what it makes. Returns whether
    /// the swipe has the movement, so the discrete swipe mustn't see it: the hold has begun
    /// one. Before that (the dead zone) and when the hold went another way, it's still
    /// `recognizer`'s, which has to count it from the press.
    private func moveDockSwipe(dx: Double, dy: Double) -> Bool {
        let frame = gestureHold?.swipe?.move(dx: dx, dy: dy, at: clock())
        guard gestureHold?.swipe?.isSwiping == true else { return false }
        if let frame { sendDockSwipe(frame) }
        return true
    }

    /// Posts a dock swipe frame, keeping the swipe that's open for a reset to cancel.
    private func sendDockSwipe(_ frame: DockSwipe.Frame) {
        switch frame.phase {
        case .began:
            GestureDebugLog.log("SWIPE began \(frame.kind) progress=\(frame.progress) after \(debugMoveCount) moves")
            openDockSwipe = frame
        case .changed:
            openDockSwipe = frame
        case .ended, .cancelled:
            GestureDebugLog.log("SWIPE \(frame.phase) \(frame.kind) progress=\(frame.progress) velocity=\(frame.velocity) after \(debugMoveCount) moves")
            openDockSwipe = nil
        }
        dockSwipes?.send(frame)
    }

    /// A hold ended early with its swipe still open: cancel it, so the Dock snaps back
    /// instead of staying halfway.
    private func cancelOpenDockSwipe() {
        guard let open = openDockSwipe else { return }
        sendDockSwipe(DockSwipe.Frame(kind: open.kind, phase: .cancelled, progress: open.progress))
    }

    /// The gesture button came back up: end the swipe that follows the pointer, so the Dock
    /// finishes it or snaps back, or else, if no swipe fired, fire the hold's `releaseSlot`
    /// (the click, or Hold for the long private key). Only the button's own release comes
    /// here: every reset of a hold sets `gestureHold` to nil instead, and fires nothing.
    /// `released` false: the end came from the hold's device going away, not from the button
    /// (`PrivateKeyEvent.deviceGone`), so a swipe ends as it would, but nothing fires.
    /// Returns whether a hold of `trigger` was in progress.
    @discardableResult
    func endGesture(trigger: Int, released: Bool = true) -> Bool {
        guard var hold = gestureHold, hold.trigger == trigger else {
            GestureDebugLog.log("end trigger=\(trigger) but no such hold (held=\(gestureHold.map { String($0.trigger) } ?? "none"))")
            return false
        }
        GestureDebugLog.log("end trigger=\(trigger) moves=\(debugMoveCount) net=(\(hold.recognizer.dx), \(hold.recognizer.dy)) fired=\(hold.recognizer.fired.map { "\($0)" } ?? "none")")
        // Sent before the hold goes, which would otherwise cancel it.
        if let end = hold.swipe?.end(at: clock()) {
            sendDockSwipe(end)
            gestureHold = nil
            return true
        }
        gestureHold = nil
        guard hold.recognizer.end(), released else { return true }
        if hold.releaseSlot == .hold { GestureDebugLog.log("long press released in place: Hold is \(hold.bindings.hold.label)") }
        perform(hold.bindings[hold.releaseSlot], trigger: trigger)
        return true
    }

    /// Ends any hold without firing anything.
    func cancelGesture() {
        gestureHold = nil
    }

    /// Fires one of a gesture's actions for a hold of `trigger`. DPI Cycle steps the DPI stage
    /// (`onDpiCycleRequest`) for the DPI button of a mouse with private keys in driver mode,
    /// where the firmware no longer does; anywhere else it goes to `apply`, which leaves it
    /// inert, as it does every action that isn't DPI Cycle to post.
    private func perform(_ action: RemapAction, trigger: Int) {
        guard action == .dpiCycle, trigger == Self.dpiButton, privateKeysActive else { return apply(action) }
        GestureDebugLog.log("DPI cycle requested")
        onDpiCycleRequest?()
    }

    private func apply(_ action: RemapAction) {
        // Nothing to post for `.passthrough` (a gesture's "None"). A gesture only ever runs
        // from a hold, never as a single action, so one nested in a gesture's slot is inert.
        // DPI Cycle is the DPI button's, in driver mode (`perform`): here it does nothing, as
        // a mouse button's mapping, the DPI button's whole action, or any other gesture's slot.
        guard action != .passthrough, action != .dpiCycle, !action.isGesture else { return }
        if let actionEmitter { actionEmitter(action); return }
        switch action {
        case .passthrough, .dpiCycle, .gesture: break
        case .keystroke(let kc, let mods, _): postKeystroke(keyCode: kc, flags: CGEventFlags(rawValue: mods))
        case .mouseButton(let b, _): postMouseClick(b)
        case .doubleClick: postDoubleClick()
        case .mediaKey(let code, _): postMediaKey(code)
        case .launchpad: LaunchpadApp.open()
        }
    }

    /// Arrow keys: a real press carries Fn and numeric pad.
    static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]
    /// Keys whose real press carries numeric pad: the arrows and the keypad's own keys
    /// (0 to 9, the operators, decimal, clear, enter and equals).
    static let numericPadKeyCodes: Set<UInt16> = arrowKeyCodes.union([
        65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92,
    ])
    /// F1 to F20, then Help, Home, Page Up, Forward Delete, End and Page Down: a real press
    /// carries Fn (Apple's NSEvent.ModifierFlags.function docs list these keys).
    static let fnKeyCodes: Set<UInt16> = arrowKeyCodes.union([
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        114, 115, 116, 117, 119, 121,
    ])

    /// The flags a keystroke goes out with: the saved ones plus the ones a real press of the
    /// key carries. macOS matches its own shortcuts on those flags, so ⌃↑ without Fn never
    /// opened Mission Control. Mappings saved before #143 lack them, and the recorder only keeps
    /// them since then, so they are added here, where every saved mapping, profile and the
    /// DPI-button bridge pass. Nothing saved is rewritten, and adding them twice changes nothing.
    static func postedFlags(keyCode: UInt16, saved: CGEventFlags) -> CGEventFlags {
        var flags = saved
        if fnKeyCodes.contains(keyCode) { flags.insert(.maskSecondaryFn) }
        if numericPadKeyCodes.contains(keyCode) { flags.insert(.maskNumericPad) }
        return flags
    }

    /// The key-down and key-up a keystroke action posts, with `postedFlags` applied.
    static func keystrokeEvents(keyCode: UInt16, saved: CGEventFlags, source: CGEventSource?) -> [CGEvent] {
        let flags = postedFlags(keyCode: keyCode, saved: saved)
        return [true, false].compactMap { keyDown in
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
            event?.flags = flags
            return event
        }
    }

    private func postKeystroke(keyCode: UInt16, flags saved: CGEventFlags) {
        Self.keystrokeEvents(keyCode: keyCode, saved: saved, source: postSource).forEach { $0.post(tap: .cghidEventTap) }
    }

    private func postMouseClick(_ button: Int) {
        let pos = CGEvent(source: nil)?.location ?? .zero
        Self.mouseClickEvents(button: button, at: pos, source: postSource).forEach { $0.post(tap: .cghidEventTap) }
    }

    /// The down and up a mouse-button action posts. Made with `postSource`, they carry `magic`
    /// and pass our own tap untouched: a gesture's click re-posts the gesture button's own
    /// number, which the tap would otherwise take for another press of it.
    static func mouseClickEvents(button: Int, at pos: CGPoint, source: CGEventSource?) -> [CGEvent] {
        let mb = CGMouseButton(rawValue: UInt32(button)) ?? .center
        let downType: CGEventType = button == 0 ? .leftMouseDown : (button == 1 ? .rightMouseDown : .otherMouseDown)
        let upType: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
        return [downType, upType].compactMap { type in
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: mb)
            // Set outright rather than trusting the conversion above: Back and Forward
            // (3 and 4) must not come out as a middle click.
            e?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            // Without a click count, apps reading NSEvent.clickCount see 0 and may not
            // treat the synthesized press as a click at all (e.g. middle-click-closes-tab).
            e?.setIntegerValueField(.mouseEventClickState, value: 1)
            return e
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

    // MARK: - DPI button software actions

    /// An action MacRazer carries out for the DPI button reaches it one of two ways. On a mouse
    /// with private keys (`supportsDpiPrivateKeys`, the Cobra HyperSpeed) the mouse is put in
    /// driver mode while one is saved (`MouseController.setDpiDriverModeWanted`) and its keys
    /// come from `privateKeySource`; its entry keeps DPI Cycle, so the button is stock with
    /// MacRazer closed. On any other (the Basilisk V3 X) the button types F20, reserved only
    /// after the mouse has confirmed that assignment, and the event tap includes keyboard
    /// events only while a software action is saved; ordinary users keep a mouse-only tap.
    ///
    /// What reaches the mouse from here: connecting, waking and opening the page only read the
    /// DPI button's entry. The one write of it not chosen on the page is the restore below,
    /// which puts F20 back after a fresh read shows the Basilisk lost it, and only while a
    /// software action is saved, which happens only after a write of F20 read back. Driver mode
    /// is `MouseController`'s to write and take back.
    func observeDpiCycle(controller: MouseController) {
        dpiObservers.removeAll()
        onDpiDriverModeWanted = { [weak controller] wanted in controller?.setDpiDriverModeWanted(wanted) }
        sentDpiDriverModeWant = nil
        onDpiCycleRequest = { [weak controller] in controller?.cycleDpiStage() }
        onMouseNotice = { [weak controller] notice in controller?.dpiDriverModeNoticed(notice) }
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
                // not fire. Re-read once in case firmware reset the physical assignment. A
                // hold of the DPI button from before the mouse slept is over.
                if self.gestureHold?.trigger == Self.dpiButton { self.cancelGesture() }
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
                guard let controller, connected, bluetooth, self.usesDpiBridge,
                      !updating, error == nil,
                      self.shouldRestoreDpiBridge(binding: binding,
                                                  connected: connected,
                                                  bluetooth: bluetooth,
                                                  alreadyAttempted: self.dpiBridgeRestoreAttempted),
                      let action = self.dpiCycleSoftwareAction else { return }
                self.dpiBridgeRestoreAttempted = true
                self.configureDpiCycle(.softwareBridge, softwareAction: action, controller: controller)
            }.store(in: &dpiObservers)

        controller.$dpiDriverMode
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.dpiDriverModeChanged(state) }
            .store(in: &dpiObservers)
        refreshDpiDriverModeWant()
    }

    /// The mouse was read holding F20, on a mouse that uses it (`usesDpiBridge`).
    func confirmDpiBridge(binding: BLEProtocol.DPIButtonBinding?) {
        dpiBridgeBindingConfirmed = usesDpiBridge && binding == .softwareBridge
    }

    func shouldRestoreDpiBridge(binding: BLEProtocol.DPIButtonBinding?, connected: Bool,
                                bluetooth: Bool, alreadyAttempted: Bool) -> Bool {
        // `binding` must have been read from the mouse: nil means "not known yet" (after a
        // reconnect), and restoring then would write before the fresh read.
        usesDpiBridge && connected && bluetooth && !alreadyAttempted
            && binding != nil && binding != .softwareBridge && dpiCycleSoftwareAction != nil
    }

    /// Writes `binding` to the mouse, and once it reads back, saves `softwareAction` as what
    /// MacRazer does with the DPI button (nil for a firmware function, which clears any saved
    /// one). A software action needs the event tap, so without it nothing is written. On a
    /// mouse with private keys the entry already holding `binding` (DPI Cycle, under any action
    /// of MacRazer's) isn't written again: the action is saved at once.
    func configureDpiCycle(_ binding: BLEProtocol.DPIButtonBinding,
                           softwareAction: RemapAction? = nil, controller: MouseController) {
        guard softwareAction == nil || remappingPermissionsGranted else { return }
        dpiBridgeBindingConfirmed = false
        if supportsDpiPrivateKeys, controller.dpiCycleButtonBinding == binding, !controller.isUpdatingDpiCycleButton {
            saveDpiSoftwareAction(softwareAction)
            return
        }
        controller.setDpiCycleButtonBinding(binding) { [weak self] success in
            guard success, let self else { return }
            self.saveDpiSoftwareAction(softwareAction)
            self.confirmDpiBridge(binding: binding)
        }
    }

    /// How the DPI button carries out `action`, or nil where this mouse can't. A function the
    /// mouse runs itself where it has one, so it works without MacRazer: DPI Cycle for None and
    /// for DPI Cycle (the whole button cycling DPI is the firmware's own job), a mouse button it
    /// can send, a key combination it can type. Anything else is MacRazer's. On a mouse with
    /// `privateKeys` that is DPI Cycle in the entry, which the button does with MacRazer closed,
    /// and driver mode while it runs. On a mouse without them (the Basilisk V3 X) it is F20 for
    /// MacRazer to turn into `action`, for exactly the actions its F20 bridge has always taken,
    /// Double Click and the media keys; anything else is nil there, so the bridge is unchanged.
    static func dpiButtonAssignment(for action: RemapAction, privateKeys: Bool = false)
        -> (binding: BLEProtocol.DPIButtonBinding, softwareAction: RemapAction?)? {
        switch action {
        case .passthrough, .dpiCycle:
            return (.dpiCycle, nil)
        case .keystroke(let keyCode, let modifiers, _):
            if let usage = BLEProtocol.hidUsage(forMacKeyCode: keyCode) {
                let flags = CGEventFlags(rawValue: modifiers)
                return (.keyboardShortcut(hidUsage: usage, modifiers: DPIShortcutModifiers.hidValue(from: flags)), nil)
            }
        case .mouseButton(let button, _):
            // CGEvent numbers 0 to 4 are the mouse's buttons 1 to 5. Its Scroll Up and Down
            // (9 and 10) are not buttons a `RemapAction` can name.
            if (0...4).contains(button),
               let binding = BLEProtocol.DPIButtonBinding.allCases.first(where: { $0.buttonID == UInt8(button + 1) }) {
                return (binding, nil)
            }
        case .doubleClick, .mediaKey:
            return (privateKeys ? .dpiCycle : .softwareBridge, action)
        case .launchpad, .gesture:
            break
        }
        return privateKeys ? (.dpiCycle, action) : nil
    }

    /// Sets the DPI button to `action` (`dpiButtonAssignment`). False, and nothing written,
    /// when this mouse can't carry it out, or when that is MacRazer's to do and the event tap
    /// isn't available.
    @discardableResult
    func configureDpiButton(_ action: RemapAction, controller: MouseController) -> Bool {
        guard let assignment = Self.dpiButtonAssignment(for: action, privateKeys: supportsDpiPrivateKeys),
              assignment.softwareAction == nil || remappingPermissionsGranted else { return false }
        configureDpiCycle(assignment.binding, softwareAction: assignment.softwareAction, controller: controller)
        return true
    }

    /// What choosing Gesture… for the DPI button does: `newDpiGesture`, carried out by
    /// MacRazer through driver mode, so only on a mouse with private keys. One that already is
    /// a gesture keeps its choices and nothing is written, as choosing it again is how the
    /// editor is reopened.
    @discardableResult
    func makeDpiGesture(controller: MouseController) -> Bool {
        guard supportsDpiPrivateKeys else { return false }
        if dpiCycleSoftwareAction?.isGesture == true { return true }
        return configureDpiButton(newDpiGesture, controller: controller)
    }

    /// A new gesture for the DPI button: the defaults, whose Click and Hold are None on every
    /// mouse (`GestureBindings.defaults(for:)`), so a short press does nothing until a choice
    /// is made. A new gesture used to click DPI Cycle on a mouse with private keys, which
    /// surprised as a short press kept changing DPI; DPI Cycle is still a choice there, and a
    /// gesture saved with it keeps it.
    var newDpiGesture: RemapAction {
        .gesture(.defaults(for: Self.dpiButton))
    }

    func dpiCycleLabel(for binding: BLEProtocol.DPIButtonBinding) -> String {
        // On a mouse with private keys the entry stays DPI Cycle under an action of MacRazer's.
        if supportsDpiPrivateKeys, let action = dpiCycleSoftwareAction,
           binding == .dpiCycle || binding == .softwareBridge {
            return action.label + " (MacRazer)"
        }
        if binding == .softwareBridge {
            return dpiCycleSoftwareAction.map { $0.label + " (MacRazer)" } ?? "MacRazer action (choose…)"
        }
        return binding.label
    }

    func saveDpiSoftwareAction(_ action: RemapAction?) {
        guard supportsDpiButtonBinding else { return }
        let previous = dpiCycleSoftwareAction
        // A hold of the DPI button was started with what it did before.
        if action != previous, gestureHold?.trigger == Self.dpiButton { gestureHold = nil }
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
        guard supportsDpiButtonBinding,
              let data = defaults.data(forKey: "dpiCycleSoftwareAction-\(activeKey)") else { return }
        dpiCycleSoftwareAction = try? JSONDecoder().decode(RemapAction.self, from: data)
    }

    /// The line under the DPI button's menu while an action of MacRazer's is saved.
    var dpiActionStatus: String { supportsDpiPrivateKeys ? dpiPrivateKeyStatus : dpiBridgeStatus }

    /// That line offers the Input Monitoring settings: the keys can't be seen without it. Not
    /// once it is granted and only a reopen is missing (`DpiDriverModeNeed.relaunch`).
    var dpiActionNeedsInputMonitoring: Bool {
        supportsDpiPrivateKeys ? currentDpiDriverModeNeed == .inputMonitoring : !keyboardCaptureAvailable
    }

    /// That line offers to reopen MacRazer (`reopenApp`): on a mouse with private keys, for
    /// as long as Input Monitoring is missing or not yet applied (`DpiDriverModeNeed.needsReopen`).
    var dpiActionNeedsReopen: Bool {
        supportsDpiPrivateKeys && currentDpiDriverModeNeed.needsReopen
    }

    /// The last `reopenApp` didn't open a new MacRazer (a copy run from the disk image, or
    /// a build without a bundle), so the page asks for it to be quit and opened by hand
    /// (`reopenFailedText`).
    @Published private(set) var reopenFailed = false
    static let reopenFailedText = "Couldn't reopen it. Quit MacRazer and open it again yourself."

    /// Opens a new MacRazer and quits this one, for an Input Monitoring grant macOS applies
    /// only to a new run. The quit is `NSApp.terminate` (`quit`), the same path as the Quit
    /// command, so `applicationWillTerminate` puts the DPI button's driver mode back before
    /// this run ends; and it comes only once the new one launched (`AppRelaunch`), so a failed
    /// open never turns into a plain quit. `opener` and `quit` are for tests.
    func reopenApp(opener: @escaping AppRelaunch.Opener = AppRelaunch.workspaceOpener,
                   quit: @escaping @MainActor @Sendable () -> Void = { NSApp.terminate(nil) }) {
        reopenFailed = false
        GestureDebugLog.log("PERMISSIONS reopening for Input Monitoring")
        AppRelaunch.openNewInstance(of: Bundle.main.bundleURL, opener: opener) { [weak self] launched in
            if launched {
                quit()
            } else {
                GestureDebugLog.log("PERMISSIONS reopen failed: no new instance launched")
                self?.reopenFailed = true
            }
        }
    }

    var dpiBridgeStatus: String {
        if !remappingPermissionsGranted { return "Input capture unavailable" }
        if !keyboardCaptureAvailable { return "Keyboard capture is blocked. Refresh Input Monitoring, then relaunch." }
        if remappingPaused { return "Waiting for mouse connection" }
        if !dpiBridgeBindingConfirmed { return "Waiting for button assignment verification" }
        return "Ready"
    }

    var dpiPrivateKeyStatus: String {
        Self.dpiPrivateKeyStatus(need: currentDpiDriverModeNeed, paused: remappingPaused, driverMode: dpiDriverMode)
    }

    /// The status line on a mouse with private keys: what it needs first (`need`), then where
    /// its driver mode stands (`DpiDriverModeState`), its error in a plain sentence.
    /// Accessibility is picked up by itself once granted (`waitsForPermission`). Input
    /// Monitoring takes effect only in a new run, so the line says to turn it on and then
    /// reopen MacRazer, and a grant macOS hasn't applied to this run says to reopen it too
    /// (`DpiDriverModeNeed.needsReopen`, which also offers the button that does it).
    static func dpiPrivateKeyStatus(need: DpiDriverModeNeed, paused: Bool,
                                    driverMode: DpiDriverModeState) -> String {
        switch need {
        case .accessibility:
            return "MacRazer needs Accessibility to carry out this action."
        case .inputMonitoring:
            return "MacRazer needs Input Monitoring to see the DPI button. Turn it on in System Settings, "
                + "then reopen MacRazer."
        case .relaunch:
            return "Input Monitoring is on, but macOS hasn't applied it to MacRazer yet. "
                + "Quit and reopen MacRazer."
        case .none, .ready:
            break
        }
        if paused { return "Waiting for mouse connection" }
        switch driverMode {
        case .engaged: return "Ready"
        case .unavailable(let text): return text
        case .off, .engaging: return "Setting up the DPI button…"
        }
    }

    /// The DPI button's F20, on a mouse that uses it (`usesDpiBridge`): a press fires the saved
    /// action, and as it always was, a gesture is never held through F20. Its repeats and
    /// release go the way the press went, as a mouse button's release does (`handle`):
    /// swallowed after a swallowed press, whatever changed in between (paused, the binding no
    /// longer confirmed, the action changed, the tap reinstalled), and through after a press an
    /// app saw. A fresh press starts over, so one whose release went by unseen can't swallow
    /// the next one's action.
    private func handleDpiBridge(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.keyboardEventKeycode) == 90 else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp {
            guard bridgeKeyIsDown else { return Unmanaged.passUnretained(event) }
            GestureDebugLog.log("F20 up, swallowed")
            bridgeKeyIsDown = false
            return nil
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return bridgeKeyIsDown ? nil : Unmanaged.passUnretained(event)
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard usesDpiBridge, dpiBridgeBindingConfirmed,
              !remappingPaused, event.flags.intersection(modifiers).isEmpty,
              let action = dpiCycleSoftwareAction else {
            bridgeKeyIsDown = false
            return Unmanaged.passUnretained(event)
        }
        GestureDebugLog.log("F20 down taken: \(action.label)")
        lastDetectedButton = Self.dpiButton
        apply(action)
        bridgeKeyIsDown = true
        return nil
    }

    // MARK: - DPI button private keys

    /// Tells `MouseController` whether the DPI button needs driver mode
    /// (`setDpiDriverModeWanted`), each time that changes. Set by `observeDpiCycle`.
    var onDpiDriverModeWanted: ((Bool) -> Void)?
    /// What it was last told, so it hears each change once.
    private var sentDpiDriverModeWant: Bool?
    /// DPI Cycle in a slot of the DPI button's gesture, in driver mode, where the firmware no
    /// longer cycles DPI itself: MacRazer's DPI cycle (`MouseController.cycleDpiStage`).
    /// Set by `observeDpiCycle`; tests catch it.
    var onDpiCycleRequest: (() -> Void)?
    /// A notification the mouse sent while its private keys are watched (`MouseNotice`), for
    /// `MouseController.dpiDriverModeNoticed`, which reads the mode at once when one suggests
    /// the firmware dropped it. Set by `observeDpiCycle`; tests catch it.
    var onMouseNotice: ((MouseNotice) -> Void)?

    /// What driver mode needs now (`DpiDriverModeNeed`), with Input Monitoring read live. Also
    /// what the status line shows.
    var currentDpiDriverModeNeed: DpiDriverModeNeed {
        DpiDriverModeNeed(privateKeys: supportsDpiPrivateKeys, action: dpiCycleSoftwareAction,
                          permissions: remappingPermissionsGranted,
                          inputMonitoring: { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted },
                          keysBlocked: privateKeyInputBlocked)
    }

    /// What `refreshDpiDriverModeWant` last worked out, for `updatePermissionRecheck`.
    private var lastDpiDriverModeNeed = DpiDriverModeNeed.none
    /// Calls `refreshAccessibility` every `permissionRecheckInterval` while `waitsForPermission`;
    /// nil otherwise, so nothing polls while no permission is awaited.
    private var permissionRecheckTimer: Timer?
    /// How often the permissions are looked at while driver mode waits for one. macOS says
    /// nothing when Accessibility is granted, and the app may not be opened in between:
    /// without this the DPI button stayed with the firmware until a relaunch. Input Monitoring
    /// is looked at too, though a grant of it has needed a reopen (`DpiDriverModeNeed.inputMonitoring`).
    static let permissionRecheckInterval: TimeInterval = 3

    /// Works out what driver mode needs, tells `MouseController` when whether it is wanted
    /// changed, and has the permissions looked at again while only one is missing. Runs
    /// wherever they are looked at anyway (`refreshAccessibility`: the Buttons page, the
    /// popover, the app coming to the front, Re-check), and on every change of device, action
    /// or tap (`installTapIfNeeded`).
    private func refreshDpiDriverModeWant() {
        guard let send = onDpiDriverModeWanted else { return }
        let need = currentDpiDriverModeNeed
        // The keys were refused while Input Monitoring wasn't granted, or it has been taken
        // back since: a grant after this is new, and gets a fresh try.
        if need == .inputMonitoring, privateKeyInputBlocked { privateKeyInputBlocked = false }
        lastDpiDriverModeNeed = need
        updatePermissionRecheck()
        let want = need.wantsDriverMode
        guard want != sentDpiDriverModeWant else { return }
        sentDpiDriverModeWant = want
        send(want)
    }

    /// Asks macOS for Input Monitoring. Asking is what puts the app in the list in System
    /// Settings, with a switch to turn on; an app that only looks (`IOHIDCheckAccess`) is never
    /// listed, and the user is left to add it by hand with the + button. The first time it
    /// also shows macOS's own prompt; once answered, asking again changes nothing. Called once
    /// when the DPI button starts waiting for the permission, and from the page's button.
    static func askForInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Starts or stops the permission timer as `DpiDriverModeNeed.rechecksPermissions` says:
    /// it runs only while driver mode waits for a permission and the mouse is connected, and
    /// stops at the first look that finds the permission there or the wait over.
    private func updatePermissionRecheck() {
        let waits = lastDpiDriverModeNeed.rechecksPermissions(paused: remappingPaused)
        if waitsForPermission != waits { waitsForPermission = waits }
        guard schedulesPermissionRechecks, !RenderOptions.isActive else { return }
        if waits, permissionRecheckTimer == nil {
            let timer = Timer(timeInterval: Self.permissionRecheckInterval, repeats: true) { [weak self] _ in
                self?.refreshAccessibility(prompt: false)
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            permissionRecheckTimer = timer
            GestureDebugLog.log("PERMISSIONS DPI button waits for \(lastDpiDriverModeNeed), looking every "
                                + "\(Int(Self.permissionRecheckInterval)) s")
            if lastDpiDriverModeNeed == .inputMonitoring { Self.askForInputMonitoring() }
        } else if !waits, let timer = permissionRecheckTimer {
            timer.invalidate()
            permissionRecheckTimer = nil
            GestureDebugLog.log("PERMISSIONS DPI button no longer waits (\(lastDpiDriverModeNeed))")
        }
    }

    /// The DPI button's keys couldn't be watched earlier in this run (`privateKeyInputBlocked`).
    /// Whether they can now is a try at opening the mouse's HID device that changes nothing on
    /// the mouse (`PrivateKeySource.canWatch`). If it opens, driver mode is wanted again, and
    /// the keys are watched for real once it is engaged. Called wherever the permissions are
    /// looked at (`refreshAccessibility`). The permission timer doesn't run for this alone
    /// (`DpiDriverModeNeed.relaunch`): the line asks for a reopen instead. Internal so tests
    /// can call it.
    func retryBlockedPrivateKeys() {
        guard privateKeyInputBlocked, supportsDpiPrivateKeys, let productID = activeDeviceID,
              privateKeySource?.canWatch(productID: productID) == true else { return }
        GestureDebugLog.log("PRIVKEY the mouse's HID device opens now: driver mode is wanted again")
        privateKeyInputBlocked = false
    }

    /// Driver mode is engaged on the connected mouse with private keys: its keys are
    /// MacRazer's to act on.
    var privateKeysActive: Bool { supportsDpiPrivateKeys && dpiDriverMode == .engaged }

    /// `MouseController` published where driver mode stands (`observeDpiCycle`). Internal so
    /// tests can say it too.
    func dpiDriverModeChanged(_ state: DpiDriverModeState) {
        guard state != dpiDriverMode else { return }
        dpiDriverMode = state
        syncPrivateKeySource()
    }

    /// Watches the private keys exactly while they are MacRazer's to act on. When they stop
    /// being so (driver mode lost, the mouse gone, another mouse), a hold of the DPI button
    /// ends: its release may never come. A mouse whose keys can't be watched doesn't need
    /// driver mode (`privateKeyInputBlocked`), so it goes back to normal until they can. The
    /// mouse's notifications come from the same watch, so only while driver mode is engaged,
    /// which is when they matter (`onMouseNotice`).
    private func syncPrivateKeySource() {
        guard privateKeysActive, let productID = activeDeviceID else {
            if privateKeySource?.isRunning == true { privateKeySource?.stop() }
            if supportsDpiPrivateKeys, gestureHold?.trigger == Self.dpiButton { gestureHold = nil }
            return
        }
        guard let privateKeySource else { return }
        if !privateKeySource.start(productID: productID, onEvent: { [weak self] in self?.handlePrivateKey($0) },
                                   onNotice: { [weak self] in self?.onMouseNotice?($0) }) {
            privateKeyInputBlocked = true
            refreshDpiDriverModeWant()
        }
    }

    /// One of the DPI button's private keys went down or up (`privateKeySource`). Main thread.
    ///
    /// With a gesture, the long key's press starts a hold as a mouse button's press does, and
    /// its release ends it; the pointer's moves in between are the swipe (`.mouseMoved`, as no
    /// mouse button is down). The long key comes only once the button has been held about a second, so a
    /// short press is the click: the short key fires the Click slot, which on DPI Cycle steps
    /// the DPI stage as the firmware would have (`onDpiCycleRequest`) and on None does nothing
    /// at all (the firmware doesn't cycle DPI in driver mode). A long hold released without a
    /// swipe fires the Hold slot, once, at the release, and only for the long key's own
    /// release: not when its device went away (`PrivateKeyEvent.deviceGone`), nor after any
    /// reset ended the hold first. Any other action fires on the short key, and a long press
    /// does nothing. Keys count only while driver mode is engaged and the mouse is connected;
    /// the short key's release, and any other code, do nothing.
    func handlePrivateKey(_ event: PrivateKeyEvent) {
        guard let keys = dpiPrivateKeys, privateKeysActive, !remappingPaused,
              let action = dpiCycleSoftwareAction else {
            GestureDebugLog.log(String(format: "PRIVKEY %02x ignored", event.code)
                                + " active=\(privateKeysActive) paused=\(remappingPaused) hasAction=\(dpiCycleSoftwareAction != nil)")
            return
        }
        switch (event.code, event.isDown) {
        case (keys.long, true):
            lastDetectedButton = Self.dpiButton
            guard case .gesture(let bindings) = action else { return }
            beginGesture(bindings, trigger: Self.dpiButton, releaseSlot: .hold)
        case (keys.long, false):
            // Nothing when the hold was already ended (paused, a mouse button pressed, …).
            endGesture(trigger: Self.dpiButton, released: !event.deviceGone)
        case (keys.short, true):
            lastDetectedButton = Self.dpiButton
            // Not a gesture: the action fires as it is. DPI Cycle as the whole action is inert
            // (`apply`): the button's own DPI Cycle (default) is the firmware's.
            guard case .gesture(let bindings) = action else { return apply(action) }
            GestureDebugLog.log("short press: Click is \(bindings.click.label)")
            perform(bindings.click, trigger: Self.dpiButton)
        default:
            break
        }
    }

    /// The choices a gesture slot's menu starts with, before the usual ones: None, and DPI
    /// Cycle on the DPI button of a mouse with private keys, where it steps the DPI stage in
    /// driver mode (`perform`): on a short press in Click, on a long press released in place
    /// in Hold, on a swipe in a direction. Every slot of that gesture offers it; no other
    /// button's, and no other mouse's.
    static func gestureSlotLeadingChoices(button: Int, privateKeys: Bool) -> [RemapAction] {
        privateKeys && button == dpiButton ? [.passthrough, .dpiCycle] : [.passthrough]
    }

    func gestureSlotLeadingChoices(of button: Int) -> [RemapAction] {
        Self.gestureSlotLeadingChoices(button: button, privateKeys: supportsDpiPrivateKeys)
    }

    /// The slots the gesture editor lists for `button`, in order. Hold only for the DPI button
    /// of a mouse with private keys, the one button with a short and a long press: on any
    /// other a press without a swipe is the click, and Hold would never fire.
    static func gestureSlots(button: Int, privateKeys: Bool) -> [GestureSlot] {
        let hasHold = privateKeys && button == dpiButton
        return GestureSlot.allCases.filter { $0 != .hold || hasHold }
    }

    func gestureSlots(of button: Int) -> [GestureSlot] {
        Self.gestureSlots(button: button, privateKeys: supportsDpiPrivateKeys)
    }

    /// A gesture slot's label in the editor: its action's, None included.
    func gestureSlotLabel(_ slot: GestureSlot, of button: Int) -> String {
        (gestureBindings(for: button)?[slot] ?? .passthrough).label
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
        mappings = decoded
        seenButtons.formUnion(decoded.keys)
    }
}

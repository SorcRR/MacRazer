// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import Darwin

/// The trackpad's Spaces and Mission Control swipes, made from a mouse. A three or four
/// finger swipe reaches the Dock as a "dock swipe": a stream of events that each say how far
/// the swipe has gone, so the desktop slides, or Mission Control opens, under the fingers,
/// and the Dock decides at the end whether to finish or snap back. A gesture button sends
/// the same stream (`DockSwipeTracker` makes it, `DockSwipePoster` posts it), so these four
/// follow the pointer instead of jumping when a shortcut fires.
///
/// None of this is public API. The event format was learned from Mac Mouse Fix (see
/// NOTICE.md) and cross-checked against other open-source apps that post it: facts only, the
/// code is this project's own. macOS 27 stopped reading these event fields (it wants an
/// IOHIDEvent attached through private SkyLight calls instead), so there `isSupported` is
/// false and the four presets fall back to their keyboard shortcuts.
enum DockSwipe {
    /// Which swipe: the event's "motion" value.
    enum Kind: Int64, Sendable {
        /// Three fingers sideways: from one Space to the next.
        case horizontal = 1
        /// Three fingers up or down: Mission Control, App Exposé.
        case vertical = 2
    }

    /// IOHIDEventPhaseBits, as a trackpad's gesture events carry them.
    enum Phase: Int64, Sendable {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8

        /// The swipe is over: the Dock finishes it or snaps back.
        var isEnd: Bool { self == .ended || self == .cancelled }
    }

    /// One event of a swipe, before it becomes CGEvents (`events(for:userData:)`).
    struct Frame: Equatable, Sendable {
        let kind: Kind
        let phase: Phase
        /// How far the swipe has gone since it began, in the Dock's units: horizontally a
        /// Space is about 1 to 2 (`Scale`), negative towards the Space on the left;
        /// vertically 1 is Mission Control fully open, negative towards Mission Control and
        /// positive towards App Exposé. Every event carries the total, not a step.
        let progress: Double
        /// Progress per second when the swipe ends, the way the hand was moving, so a flick
        /// can finish a swipe that hasn't gone far. 0 until the end.
        var velocity: Double = 0
    }

    /// Whether this macOS reads the event fields `events(for:userData:)` writes.
    static var isSupported: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 }

    // The undocumented CGEvent fields of a dock swipe. A trackpad's own events carry them,
    // and the Dock reads them back; the numbers are CGEventField raw values.

    /// The event type, as on the event itself: 30 for the swipe, 29 for the gesture event
    /// that follows it.
    static let typeField: UInt32 = 55
    /// Which kind of gesture the event carries: an IOHIDEventType.
    static let gestureTypeField: UInt32 = 110
    /// kIOHIDEventTypeDockSwipe.
    static let dockSwipeGestureType: Int64 = 23
    /// The phase (`Phase`), in two fields.
    static let phaseFields: [UInt32] = [132, 134]
    /// The swipe's kind (`Kind`), in two fields.
    static let kindFields: [UInt32] = [123, 165]
    /// The kind again, as the 32-bit float whose bits are the kind's number (a denormal).
    static let kindAsFloatBitsFields: [UInt32] = [119, 139]
    /// The progress as a double.
    static let progressField: UInt32 = 124
    /// The progress again, as the bits of a 32-bit float in an integer field. The Dock is
    /// reported to need both.
    static let progressFloatBitsField: UInt32 = 135
    /// The velocity at the end, in two fields (x and y, always equal here).
    static let velocityFields: [UInt32] = [129, 130]
    /// Set by a trackpad whose deltas are inverted (natural scrolling). It changes how the
    /// Dock reads a pinch, not these two kinds; 1 for vertical and 0 for horizontal are the
    /// values whose directions were checked on real Macs (see `Frame.progress`).
    static let invertedFromDeviceField: UInt32 = 136
    /// A field a trackpad's gesture events carry with this value. Its meaning is unknown; it
    /// is copied because it costs nothing.
    static let unknownField: UInt32 = 41
    static let unknownFieldValue: Int64 = 33231
    /// The event types: a swipe event, then a plain gesture event after it.
    static let swipeEventType: Int64 = 30
    static let gestureEventType: Int64 = 29

    /// The two events one frame posts, in the order to post them: the swipe event, then the
    /// gesture event the Dock expects after it. Both carry `userData`, so a tap of ours that
    /// sees them can tell they are ours. Pure: nothing is posted here.
    static func events(for frame: Frame, userData: Int64) -> [CGEvent] {
        guard let swipe = CGEvent(source: nil), let companion = CGEvent(source: nil) else { return [] }
        func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }

        swipe.setIntegerValueField(field(typeField), value: swipeEventType)
        swipe.setIntegerValueField(field(gestureTypeField), value: dockSwipeGestureType)
        for raw in phaseFields { swipe.setIntegerValueField(field(raw), value: frame.phase.rawValue) }
        for raw in kindFields { swipe.setIntegerValueField(field(raw), value: frame.kind.rawValue) }
        let kindBits = Double(Float32(bitPattern: UInt32(frame.kind.rawValue)))
        for raw in kindAsFloatBitsFields { swipe.setDoubleValueField(field(raw), value: kindBits) }
        swipe.setDoubleValueField(field(progressField), value: frame.progress)
        swipe.setIntegerValueField(field(progressFloatBitsField),
                                   value: Int64(Float32(frame.progress).bitPattern))
        swipe.setIntegerValueField(field(invertedFromDeviceField), value: frame.kind == .vertical ? 1 : 0)
        if frame.phase.isEnd {
            for raw in velocityFields { swipe.setDoubleValueField(field(raw), value: frame.velocity) }
        }
        swipe.setIntegerValueField(field(unknownField), value: unknownFieldValue)

        companion.setIntegerValueField(field(typeField), value: gestureEventType)
        companion.setIntegerValueField(field(unknownField), value: unknownFieldValue)

        for event in [swipe, companion] { event.setIntegerValueField(.eventSourceUserData, value: userData) }
        return [swipe, companion]
    }

    /// How far the pointer must go for the swipe to go a given way: progress per point of
    /// pointer movement, for each kind. Taken when a hold starts, from the screen under the
    /// pointer (`current`).
    struct Scale: Equatable, Sendable {
        var horizontal: Double
        var vertical: Double

        func perPoint(_ kind: Kind) -> Double { kind == .horizontal ? horizontal : vertical }

        /// The gap the Dock draws between two Spaces as they slide, in points.
        static let spaceGap: Double = 63
        /// What `perSpace` assumes when the number of Spaces can't be read: three.
        static let assumedSpaces = 3

        /// The horizontal progress of one whole Space. It depends on how many Spaces the
        /// display has: 2 with one or two, then 1 + 1/(n - 1), down towards 1.
        static func perSpace(_ spaces: Int) -> Double {
            spaces <= 2 ? 2 : 1 + 1 / Double(spaces - 1)
        }

        /// The scale on a screen of `size` with `spaces` Spaces (nil when unknown). The
        /// desktop then slides with the pointer, a whole Space for the screen's width and the
        /// gap after it, and Mission Control opens fully over the screen's height. Both are
        /// starting points that need trying on real hardware: they make a long movement on a
        /// wide screen, and only a flick or most of the way finishes a swipe.
        static func screen(size: CGSize, spaces: Int?) -> Scale {
            let width = max(size.width, 1), height = max(size.height, 1)
            return Scale(horizontal: perSpace(spaces ?? assumedSpaces) / (width + spaceGap),
                         vertical: 1 / height)
        }

        /// The scale for the screen under the pointer now. Main thread only, as the tap is.
        static func current() -> Scale {
            let screen: (size: CGSize, displayID: CGDirectDisplayID?) = MainActor.assumeIsolated {
                let pointer = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
                let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                return (screen?.frame.size ?? CGSize(width: 1440, height: 900),
                        (number as? NSNumber).map { CGDirectDisplayID($0.uint32Value) })
            }
            return Scale.screen(size: screen.size, spaces: screen.displayID.flatMap(ManagedSpaces.count(onDisplay:)))
        }
    }
}

/// How many Spaces a display has, from the window server's own list. Private API, looked up
/// at run time so a macOS without it only loses the count (`Scale.assumedSpaces`).
private enum ManagedSpaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let functions: (MainConnection, CopyDisplaySpaces)? = {
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(everywhere, "CGSMainConnectionID"),
              let copy = dlsym(everywhere, "CGSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self), unsafeBitCast(copy, to: CopyDisplaySpaces.self))
    }()

    /// The display's Spaces, or nil when the list can't be read. With "Displays have
    /// separate Spaces" off there is one entry for every display.
    static func count(onDisplay displayID: CGDirectDisplayID) -> Int? {
        guard let (connection, copy) = functions,
              let displays = copy(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let entry: [String: Any]?
        if displays.count == 1 {
            entry = displays.first
        } else {
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
            let name = uuid.map { CFUUIDCreateString(nil, $0) as String }
            entry = displays.first { ($0["Display Identifier"] as? String) == name }
        }
        return (entry?["Spaces"] as? [Any])?.count
    }
}

/// One of the four system presets a gesture slot can hold that follow the pointer
/// (`DockSwipeTracker`). A slot holds a preset as the very value the menu put there
/// (`RemapPreset.action`), name included: that is what tells it from the same keys recorded
/// as a custom shortcut, which stays a plain keystroke. The flags may lack Fn and numeric pad
/// (`ButtonRemapper.postedFlags` adds them anyway). A preset renamed later must keep
/// matching values saved under its old name here.
enum SystemSwipe: CaseIterable, Sendable {
    case missionControl, appExpose, spaceLeft, spaceRight

    /// The preset's id in `ButtonRemapper.presets`.
    var presetID: String {
        switch self {
        case .missionControl: "missionControl"
        case .appExpose: "appExpose"
        case .spaceLeft: "spaceLeft"
        case .spaceRight: "spaceRight"
        }
    }

    var kind: DockSwipe.Kind {
        switch self {
        case .missionControl, .appExpose: .vertical
        case .spaceLeft, .spaceRight: .horizontal
        }
    }

    /// The sign of the progress that heads for this one (`DockSwipe.Frame.progress`).
    var progressSign: Double {
        switch self {
        case .missionControl, .spaceLeft: -1
        case .appExpose, .spaceRight: 1
        }
    }

    /// The same swipe the other way.
    var opposite: SystemSwipe {
        switch self {
        case .missionControl: .appExpose
        case .appExpose: .missionControl
        case .spaceLeft: .spaceRight
        case .spaceRight: .spaceLeft
        }
    }

    /// The system swipe `action` is, or nil for any other action.
    init?(_ action: RemapAction) {
        guard case .keystroke(let keyCode, let modifiers, let name) = action else { return nil }
        let flags = ButtonRemapper.postedFlags(keyCode: keyCode, saved: CGEventFlags(rawValue: modifiers))
        let match = Self.allCases.first { swipe in
            guard let preset = ButtonRemapper.presets.first(where: { $0.id == swipe.presetID }) else { return false }
            return preset.keyCode == keyCode && preset.name == name
                && ButtonRemapper.postedFlags(keyCode: keyCode, saved: preset.flags) == flags
        }
        guard let match else { return nil }
        self = match
    }
}

/// The system swipe each direction of a gesture holds, if any. Worked out once when a hold
/// starts, so the pointer's events only read it.
struct SystemSwipeSlots: Equatable, Sendable {
    var up: SystemSwipe?
    var down: SystemSwipe?
    var left: SystemSwipe?
    var right: SystemSwipe?

    init(up: SystemSwipe? = nil, down: SystemSwipe? = nil, left: SystemSwipe? = nil, right: SystemSwipe? = nil) {
        self.up = up; self.down = down; self.left = left; self.right = right
    }

    init(_ bindings: GestureBindings) {
        self.init(up: SystemSwipe(bindings.up), down: SystemSwipe(bindings.down),
                  left: SystemSwipe(bindings.left), right: SystemSwipe(bindings.right))
    }

    var isEmpty: Bool { up == nil && down == nil && left == nil && right == nil }

    func contains(_ swipe: SystemSwipe) -> Bool { [up, down, left, right].contains(swipe) }

    /// The same slots with `swipe` taken out wherever it is: those directions become ordinary
    /// actions again, fired once by the discrete swipe.
    func removing(_ swipe: SystemSwipe) -> SystemSwipeSlots {
        SystemSwipeSlots(up: up == swipe ? nil : up, down: down == swipe ? nil : down,
                         left: left == swipe ? nil : left, right: right == swipe ? nil : right)
    }

    subscript(direction: GestureDirection) -> SystemSwipe? {
        switch direction {
        case .up: up
        case .down: down
        case .left: left
        case .right: right
        }
    }
}

/// Turns the pointer movement of one gesture-button hold into a dock swipe (`DockSwipe.Frame`)
/// when the way it starts going is a system swipe (`SystemSwipe`). Pure and O(1) per event:
/// the remapper feeds it every movement with the time, and posts what it returns.
///
/// Inside `deadZone` nothing happens, so a click's drift is still a click. Past it the
/// larger axis is locked for the rest of the hold, as on a trackpad, and the direction the
/// pointer went decides: a system swipe there begins at once and follows every movement
/// along that axis, backwards too; anything else leaves the hold to the discrete swipe
/// (`GestureRecognizer`) and this does nothing more.
///
/// The sign follows the slots, not the screen: moving towards the slot that holds Space Left
/// heads for the Space on the left, whichever slot that is. Moving back past the start goes
/// on into the opposite slot's swipe when that is the same swipe the other way (Space Right
/// opposite Space Left, App Exposé opposite Mission Control). When the opposite slot is
/// anything else (another action, None, or the other kind of swipe, which can't take over a
/// swipe already under way), the progress stops at zero instead: the swipe can be taken back,
/// but not turned into something else.
struct DockSwipeTracker: Equatable, Sendable {
    /// How far, in points, the pointer must go along one axis before the hold is a swipe.
    /// Above a click's drift, below the discrete swipe's `GestureRecognizer.threshold`.
    static let deadZone: Double = 12
    /// The least time between two `changed` frames. A mouse polling at 1000 Hz would
    /// otherwise send the Dock eight frames for every one a 120 Hz display shows; one polling
    /// at 125 Hz, as over Bluetooth, keeps every frame. The end always carries the latest
    /// progress, so nothing is lost.
    static let minimumFrameInterval: TimeInterval = 1.0 / 240
    /// How quickly the velocity forgets older movement, in seconds.
    static let velocitySmoothing: TimeInterval = 0.05

    enum State: Equatable, Sendable {
        /// Still inside the dead zone.
        case undecided
        /// Past it, the way of a slot that isn't a system swipe: the discrete swipe's hold.
        case discrete
        /// A dock swipe has begun and not ended.
        case swiping
        /// Its end (or cancel) was returned.
        case finished
    }

    let slots: SystemSwipeSlots
    let scale: DockSwipe.Scale
    private(set) var state = State.undecided
    /// The swipe of the slot the pointer first went towards, once one began.
    private(set) var swipe: SystemSwipe?
    /// The progress so far (`DockSwipe.Frame.progress`).
    private(set) var progress: Double = 0
    /// When the pointer last moved.
    private var lastMoveAt: TimeInterval
    /// Net movement while undecided.
    private var dx: Double = 0
    private var dy: Double = 0
    /// Smoothed pointer velocity in points per second, both axes from the start of the hold,
    /// and movement not yet in it (`trackVelocity`).
    private var velocityX: Double = 0
    private var velocityY: Double = 0
    private var unmeasuredX: Double = 0
    private var unmeasuredY: Double = 0
    /// The locked axis is the horizontal one.
    private var horizontalAxis = true
    /// Progress per point of movement along the locked axis, signed for the slots.
    private var gain: Double = 0
    /// The sign the progress must keep, or 0 when it may cross the start (see above).
    private var keepSign: Double = 0
    private var lastFrameAt: TimeInterval = 0

    init(slots: SystemSwipeSlots, scale: DockSwipe.Scale, at time: TimeInterval) {
        self.slots = slots
        self.scale = scale
        self.lastMoveAt = time
    }

    var isSwiping: Bool { state == .swiping }
    /// The hold went past the dead zone.
    var leftDeadZone: Bool { state != .undecided }

    /// Adds a movement (CGEvent deltas: y grows downward) made at `time` (seconds, any
    /// monotonic clock). Returns the frame to post: `began` as the hold leaves the dead zone
    /// towards a system swipe, then `changed` as it moves on, at most every
    /// `minimumFrameInterval`. Nil otherwise.
    mutating func move(dx: Double, dy: Double, at time: TimeInterval) -> DockSwipe.Frame? {
        trackVelocity(dx: dx, dy: dy, at: time)
        switch state {
        case .undecided:
            self.dx += dx
            self.dy += dy
            return lockIfPastDeadZone(at: time)
        case .swiping:
            let moved = clamped(progress + gain * (horizontalAxis ? dx : dy))
            guard moved != progress, let swipe else { return nil }
            progress = moved
            guard time - lastFrameAt >= Self.minimumFrameInterval else { return nil }
            lastFrameAt = time
            return DockSwipe.Frame(kind: swipe.kind, phase: .changed, progress: progress)
        case .discrete, .finished:
            return nil
        }
    }

    private mutating func lockIfPastDeadZone(at time: TimeInterval) -> DockSwipe.Frame? {
        let horizontal = abs(dx), vertical = abs(dy)
        guard max(horizontal, vertical) > Self.deadZone else { return nil }
        // An exact diagonal goes to the horizontal axis, as in `GestureRecognizer`.
        horizontalAxis = horizontal >= vertical
        let direction: GestureDirection = horizontalAxis ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
        guard let swipe = slots[direction] else {
            state = .discrete
            return nil
        }
        // Pointer deltas grow right and down; the gain turns them into progress that heads
        // for this slot's swipe when the pointer goes this slot's way.
        let pointerSign: Double = direction == .right || direction == .down ? 1 : -1
        gain = swipe.progressSign * pointerSign * scale.perPoint(swipe.kind)
        keepSign = slots[direction.opposite] == swipe.opposite ? 0 : swipe.progressSign
        self.swipe = swipe
        state = .swiping
        // The dead zone's movement counts, so the desktop is where the pointer is.
        progress = gain * (horizontalAxis ? dx : dy)
        lastFrameAt = time
        return DockSwipe.Frame(kind: swipe.kind, phase: .began, progress: progress)
    }

    /// An exponential average of the pointer's speed, weighted by time: steady movement reads
    /// as its own speed, whatever the polling rate. Movement that comes with no time since the
    /// last (two events handled together) waits and counts with the next.
    private mutating func trackVelocity(dx: Double, dy: Double, at time: TimeInterval) {
        unmeasuredX += dx
        unmeasuredY += dy
        let elapsed = time - lastMoveAt
        guard elapsed > 0 else { return }
        let keep = exp(-elapsed / Self.velocitySmoothing)
        velocityX = velocityX * keep + (1 - keep) * unmeasuredX / elapsed
        velocityY = velocityY * keep + (1 - keep) * unmeasuredY / elapsed
        unmeasuredX = 0
        unmeasuredY = 0
        lastMoveAt = time
    }

    private func clamped(_ value: Double) -> Double {
        keepSign == 0 ? value : keepSign * max(keepSign * value, 0)
    }

    /// The hold is over at `time`: the button came up. Returns the frame that ends the swipe,
    /// nil when none began. `ended` carries the velocity, which fades the longer the pointer
    /// has been still before `time`, so a flick finishes and a stop leaves it to the progress.
    /// `cancelled` when the pointer was on its way back towards the start, or is there: the
    /// swipe snaps back, as a trackpad's does when the fingers come back before lifting.
    mutating func end(at time: TimeInterval) -> DockSwipe.Frame? {
        guard state == .swiping, let swipe else { return nil }
        state = .finished
        let fade = exp(-max(time - lastMoveAt, 0) / Self.velocitySmoothing)
        let velocity = gain * (horizontalAxis ? velocityX : velocityY) * fade
        let phase: DockSwipe.Phase = progress == 0 || velocity * progress < 0 ? .cancelled : .ended
        return DockSwipe.Frame(kind: swipe.kind, phase: phase, progress: progress, velocity: velocity)
    }

    /// Ends the swipe without finishing it, for a hold that stops early. Nil when none began.
    mutating func cancel() -> DockSwipe.Frame? {
        guard state == .swiping, let swipe else { return nil }
        state = .finished
        return DockSwipe.Frame(kind: swipe.kind, phase: .cancelled, progress: progress)
    }
}

private extension GestureDirection {
    var opposite: GestureDirection {
        switch self {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }
}

/// Where the remapper's dock swipes go: the frames, and the scale to make them with. Tests
/// pass a recorder; the app passes `system(userData:)`.
struct DockSwipeOutput {
    let send: (DockSwipe.Frame) -> Void
    /// The scale for a hold starting now (`DockSwipe.Scale.current`).
    let scale: () -> DockSwipe.Scale
    /// Whether the Dock acts on an App Exposé swipe now (`DockGestures.appExposeEnabled`),
    /// asked as each hold starts. Tests say yes unless they test the other way.
    let appExposeEnabled: () -> Bool

    init(send: @escaping (DockSwipe.Frame) -> Void, scale: @escaping () -> DockSwipe.Scale,
         appExposeEnabled: @escaping () -> Bool = { true }) {
        self.send = send
        self.scale = scale
        self.appExposeEnabled = appExposeEnabled
    }

    /// Posts to the session, or nil on a macOS that ignores these events
    /// (`DockSwipe.isSupported`), whose system swipes stay keyboard shortcuts.
    static func system(userData: Int64) -> DockSwipeOutput? {
        guard DockSwipe.isSupported else { return nil }
        let poster = DockSwipePoster(userData: userData)
        return DockSwipeOutput(send: poster.post, scale: DockSwipe.Scale.current,
                               appExposeEnabled: DockGestures.appExposeEnabled)
    }
}

/// The Dock's own trackpad gesture settings, as far as the dock swipes need them. App
/// Exposé's is off out of the box, and while it is off the Dock ignores an App Exposé swipe
/// entirely (seen on macOS 26.3, where it did nothing), so the preset falls back to its ⌃↓
/// shortcut there (`ButtonRemapper.dockSwipeTracker(for:)`). Mission Control's and the
/// Spaces' swipes are on out of the box and are always sent.
enum DockGestures {
    static let dockDomain = "com.apple.dock"
    /// System Settings › Trackpad › More Gestures › App Exposé.
    static let appExposeKey = "showAppExposeGestureEnabled"

    /// Read fresh each time: the setting can change in System Settings while MacRazer runs.
    static func appExposeEnabled() -> Bool {
        let domain = dockDomain as CFString
        CFPreferencesAppSynchronize(domain)
        return isOn(CFPreferencesCopyAppValue(appExposeKey as CFString, domain))
    }

    /// A stored value as a switch: on only for a number or boolean that says so, so a setting
    /// never written reads as off, the macOS default.
    static func isOn(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }
}

/// Posts dock swipe frames (`DockSwipe.events(for:userData:)`) at the session, as a
/// trackpad's arrive. Main thread only, like the tap that drives it.
///
/// Under load the Dock can miss an end, which leaves the desktop stuck halfway between two
/// Spaces until the next swipe. So each end goes out again `endRepeats` later. The next
/// swipe's start stops any repeat still waiting: a late end would cut that swipe short.
final class DockSwipePoster: @unchecked Sendable {
    static let endRepeats: [TimeInterval] = [0.2, 0.5]

    private let userData: Int64
    private let send: (CGEvent) -> Void
    /// The last end's events, and the timers that post them again. Readable so tests can
    /// see them waiting and fire them.
    private var lastEnd: [CGEvent] = []
    private(set) var repeatTimers: [Timer] = []

    init(userData: Int64, send: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }) {
        self.userData = userData
        self.send = send
    }

    deinit { repeatTimers.forEach { $0.invalidate() } }

    func post(_ frame: DockSwipe.Frame) {
        if frame.phase == .began || frame.phase.isEnd { stopRepeats() }
        let events = DockSwipe.events(for: frame, userData: userData)
        events.forEach(send)
        guard frame.phase.isEnd else { return }
        lastEnd = events
        repeatTimers = Self.endRepeats.map { delay in
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in self?.repeatEnd(timer) }
            // Common modes, as the tap's source: the repeat still goes while a menu is tracking.
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
    }

    private func repeatEnd(_ timer: Timer) {
        guard repeatTimers.contains(where: { $0 === timer }) else { return }
        repeatTimers.removeAll { $0 === timer }
        lastEnd.forEach(send)
        if repeatTimers.isEmpty { lastEnd = [] }
    }

    private func stopRepeats() {
        repeatTimers.forEach { $0.invalidate() }
        repeatTimers = []
        lastEnd = []
    }
}

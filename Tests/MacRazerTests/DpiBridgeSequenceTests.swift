// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CoreGraphics
import XCTest
@testable import MacRazer

/// The DPI button's F20 (`handleDpiBridge`) under any order of key events and changes a run
/// can bring: pausing, the binding confirmed or not, the action saved or removed, another
/// device, Shift held, and a gesture added or removed, which reinstalls the tap. The real app
/// reinstalls it in `installTapIfNeeded`, which tests can't reach without a real tap, so the
/// harness does what it does there: whenever the wanted mask changes, it calls `tapReplaced`
/// with the new mask, and from then on routes key events to `handle` only while that mask has
/// the keys. Without them the events go straight to the app, as they would.
///
/// What must hold, for one physical key pressed and let go in order:
/// - A press the tap sees fires the action exactly when it is swallowed, and is swallowed
///   exactly when the bridge is on for it (the Basilisk, confirmed, not paused, no modifier,
///   an action saved). A repeat or a release never fires anything.
/// - A press the app saw has its repeats and release go through: never a key stuck down.
/// - A press the tap swallowed has its repeats and release swallowed, as long as the tap kept
///   the keys the whole time: never a lone release. (A tap that lost the keys mid-press
///   forgets the press on purpose, `tapReplaced`; that case is not checked.)
///
/// The runs also lose an event now and then, as when macOS switches the tap off for a moment
/// (`tapDisabledByTimeout`): it goes straight to the app. A press whose release went by
/// unseen that way mustn't change the next press the tap sees, which starts over. One case
/// is left out: a press whose key down went by unseen right after such a release, as the tap
/// can't tell its release from the lost one's.
final class DpiBridgeSequenceTests: XCTestCase {
    private let basilisk = 0x00BA
    /// The same model over its dongle, which can't bind the DPI button.
    private let dongle = 0x00B9
    private let back = 3
    private let playPause = RemapAction.mediaKey(code: 16, name: "Play / Pause")

    private final class Emitted { var actions: [RemapAction] = [] }

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private enum Step: CaseIterable, CustomStringConvertible {
        case down, repeatKey, up
        case togglePause, toggleConfirm, toggleAction, toggleDevice, toggleShift, toggleGesture
        /// The next key event the tap would see goes by unseen: the tap was off for a moment.
        case lose

        var description: String {
            switch self {
            case .down: "down"
            case .repeatKey: "repeat"
            case .up: "up"
            case .togglePause: "pause"
            case .toggleConfirm: "confirm"
            case .toggleAction: "action"
            case .toggleDevice: "device"
            case .toggleShift: "shift"
            case .toggleGesture: "gesture"
            case .lose: "lose"
            }
        }
    }

    /// One run: the remapper, the tap the real app would have, and what the app has seen.
    private final class Harness {
        let r: ButtonRemapper
        let emitted: Emitted
        let playPause: RemapAction
        let basilisk: Int
        let dongle: Int
        let back: Int
        /// The mask of the tap the real app would have installed.
        var mask: CGEventMask
        var onBasilisk = true
        var actionSaved = true
        var confirmed = true
        var gesture = false
        var shift = false
        /// The physical key.
        var held = false
        /// The app saw this press's key down (through the tap or around it).
        var appSawDown = false
        /// The tap lost the keys at some point since this press went down.
        var keysLostDuringPress = false
        /// The next key event the tap would see goes straight to the app (`Step.lose`).
        var loseNext = false
        /// The release of a press the tap swallowed went by unseen, and the tap hasn't seen a
        /// key down since: it may still take the key for down.
        var staleFlag = false
        /// This press's key down went by unseen while `staleFlag`: left out (see above).
        var exemptPress = false
        var exempted = 0
        var expectedActions = 0
        var log: [String] = []

        init(defaults: UserDefaults, playPause: RemapAction, basilisk: Int, dongle: Int, back: Int) {
            let emitted = Emitted()
            self.emitted = emitted
            self.playPause = playPause
            self.basilisk = basilisk
            self.dongle = dongle
            self.back = back
            r = ButtonRemapper(defaults: defaults, actionEmitter: { emitted.actions.append($0) })
            r.setActiveDevice("BASILISK-BT", deviceID: basilisk)
            r.saveDpiSoftwareAction(playPause)
            r.confirmDpiBridge(binding: .softwareBridge)
            mask = r.wantedEventMask
        }

        var tapHasKeys: Bool { ButtonRemapper.includesKeyboardEvents(mask) }

        /// What `installTapIfNeeded` does after a change, for the F20 flag.
        func syncTap() {
            let wanted = r.wantedEventMask
            guard wanted != mask else { return }
            if !ButtonRemapper.includesKeyboardEvents(wanted) {
                if held, tapHasKeys { keysLostDuringPress = true }
                staleFlag = false
            }
            r.tapReplaced(mask: wanted)
            mask = wanted
        }

        /// Sends a key event the way the session would: through the tap while it has the keys,
        /// straight to the app otherwise. Returns whether the tap saw it, and whether it passed.
        func key(down: Bool, repeating: Bool = false) -> (seen: Bool, passed: Bool) {
            guard tapHasKeys else { return (false, true) }
            if loseNext {
                loseNext = false
                _ = r.handle(type: .tapDisabledByTimeout, event: CGEvent(source: nil)!)
                return (false, true)
            }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 90, keyDown: down)!
            if repeating { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            event.flags = shift ? [.maskShift, .maskSecondaryFn] : [.maskSecondaryFn]
            return (true, r.handle(type: down ? .keyDown : .keyUp, event: event) != nil)
        }

        /// Whether `step` can happen now: the key goes down, repeats and comes up in order.
        func allows(_ step: Step) -> Bool {
            switch step {
            case .down: !held
            case .repeatKey, .up: held
            case .toggleAction: onBasilisk
            case .lose: tapHasKeys && !loseNext
            default: true
            }
        }

        /// Takes `step`. Returns a failure message, or nil.
        func take(_ step: Step) -> String? {
            log.append(step.description)
            switch step {
            case .down:
                held = true
                keysLostDuringPress = false
                let bridgeOn = onBasilisk && confirmed && actionSaved && !r.remappingPaused && !shift
                let before = emitted.actions.count
                let (seen, passed) = key(down: true)
                appSawDown = passed
                exemptPress = !seen && staleFlag
                if seen { staleFlag = false }
                if seen, bridgeOn {
                    expectedActions += 1
                    if passed { return "a press the bridge takes went through" }
                } else if !passed {
                    return "a press the bridge doesn't take was swallowed"
                }
                if emitted.actions.count - before != (seen && bridgeOn ? 1 : 0) {
                    return "the press fired \(emitted.actions.count - before) times"
                }
            case .repeatKey, .up:
                if step == .up { held = false }
                let before = emitted.actions.count
                let (seen, passed) = key(down: step == .repeatKey, repeating: step == .repeatKey)
                if emitted.actions.count != before { return "a \(step) fired an action" }
                if step == .up, !seen, tapHasKeys, !appSawDown, !keysLostDuringPress { staleFlag = true }
                guard seen else { return nil }
                if exemptPress { exempted += 1; return nil }
                if appSawDown, !passed { return "the \(step) of a press the app saw was swallowed: key stuck down" }
                if !appSawDown, !keysLostDuringPress, passed {
                    return "the \(step) of a swallowed press went through: a lone \(step)"
                }
            case .togglePause:
                r.remappingPaused.toggle()
            case .toggleConfirm:
                confirmed.toggle()
                r.confirmDpiBridge(binding: confirmed ? .softwareBridge : .dpiCycle)
            case .toggleAction:
                actionSaved.toggle()
                r.saveDpiSoftwareAction(actionSaved ? playPause : nil)
            case .toggleDevice:
                onBasilisk.toggle()
                r.setActiveDevice(onBasilisk ? "BASILISK-BT" : "BASILISK-DONGLE",
                                  deviceID: onBasilisk ? basilisk : dongle)
                // A device change drops the confirmation; the gesture and the action are
                // the device's own.
                confirmed = false
                gesture = r.mappings[back]?.isGesture == true
                if onBasilisk { actionSaved = r.dpiCycleSoftwareAction != nil }
            case .toggleShift:
                shift.toggle()
            case .toggleGesture:
                gesture.toggle()
                if gesture { r.makeGesture(back) } else { r.setAction(.passthrough, for: back) }
            case .lose:
                loseNext = true
            }
            syncTap()
            if onBasilisk, actionSaved != (r.dpiCycleSoftwareAction != nil) { return "the model lost track of the action" }
            if emitted.actions.count != expectedActions {
                return "\(emitted.actions.count) actions fired, \(expectedActions) expected"
            }
            return nil
        }
    }

    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "MacRazerTests.DpiBridgeSequence.\(name)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func harness(_ defaults: UserDefaults) -> Harness {
        Harness(defaults: defaults, playPause: playPause, basilisk: basilisk, dongle: dongle, back: back)
    }

    /// A fixed seed, so a failure names a sequence that can be run again.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testTheDevicesTheHarnessUses() {
        XCTAssertTrue(RazerDevices.supportsDpiButtonBinding(pid: basilisk))
        XCTAssertFalse(RazerDevices.supportsDpiButtonBinding(pid: dongle))
        let h = harness(defaults())
        XCTAssertTrue(h.tapHasKeys, "the bridge starts on, with the keys")
        h.r.makeGesture(back)
        XCTAssertNotEqual(h.r.wantedEventMask, h.mask, "a gesture changes the mask, so the tap is reinstalled")
    }

    /// Every rule above, over many random runs from a fixed seed. Key events come about half
    /// the time, so presses are long enough for changes to fall inside them.
    func testF20HoldsItsRulesUnderRandomRuns() {
        let defaults = defaults()
        var rng = SplitMix64(state: 0x00BA_F20)
        var pressesSeen = 0
        var exempted = 0
        for run in 0..<1500 {
            defaults.removePersistentDomain(forName: suites.last!)
            let h = harness(defaults)
            for _ in 0..<30 {
                let keySteps: [Step] = [.down, .repeatKey, .up]
                let pool: [Step] = Bool.random(using: &rng) ? keySteps : Step.allCases
                let candidates = pool.filter(h.allows)
                guard let step = candidates.randomElement(using: &rng) else { continue }
                if step == .down, h.tapHasKeys { pressesSeen += 1 }
                if let failure = h.take(step) {
                    XCTFail("run \(run): \(failure) after \(h.log.joined(separator: ", "))")
                    return
                }
            }
            exempted += h.exempted
        }
        XCTAssertGreaterThan(pressesSeen, 1000, "the runs reach the tap")
        XCTAssertLessThan(exempted, pressesSeen / 20, "the case left out stays rare")
    }

    // MARK: The sequences the change is about

    /// Paused, a press goes through to the app; unpausing and adding a gesture (a reinstall
    /// that keeps the keys) mid-press must not swallow its repeats or release.
    func testAPressTheAppSawKeepsGoingThroughAReinstall() {
        let h = harness(defaults())
        for step: Step in [.togglePause, .down, .togglePause, .toggleGesture, .repeatKey, .up] {
            if let failure = h.take(step) { return XCTFail("\(failure) after \(h.log)") }
        }
        XCTAssertEqual(h.emitted.actions, [])
    }

    /// Shift held as the key goes down: it goes through, and so does its release after Shift
    /// is let go, when the bridge would take a fresh press.
    func testAPressWithShiftKeepsItsReleaseWhenShiftGoes() {
        let h = harness(defaults())
        for step: Step in [.toggleShift, .down, .toggleShift, .repeatKey, .up, .down, .up] {
            if let failure = h.take(step) { return XCTFail("\(failure) after \(h.log)") }
        }
        XCTAssertEqual(h.emitted.actions, [playPause], "only the press without Shift")
    }

    /// The binding confirmed mid-press (the read came back while the button was held) leaves
    /// that press the app's to the end; the next one is the bridge's.
    func testABindingConfirmedMidPressLeavesThatPressToTheApp() {
        let h = harness(defaults())
        for step: Step in [.toggleConfirm, .down, .toggleConfirm, .repeatKey, .up, .down, .repeatKey, .up] {
            if let failure = h.take(step) { return XCTFail("\(failure) after \(h.log)") }
        }
        XCTAssertEqual(h.emitted.actions, [playPause])
    }

    /// Switching to the dongle and back mid-press: the keys go and come back, the press the
    /// tap swallowed is forgotten, and the next press, unconfirmed after the switch, is the
    /// app's from start to end.
    func testADeviceSwitchMidPressThenAFreshPress() {
        let h = harness(defaults())
        for step: Step in [.down, .toggleDevice, .up, .toggleDevice, .down, .repeatKey, .up,
                           .toggleConfirm, .down, .repeatKey, .up] {
            if let failure = h.take(step) { return XCTFail("\(failure) after \(h.log)") }
        }
        XCTAssertEqual(h.emitted.actions, [playPause, playPause])
    }

    /// A press whose release went by unseen (the tap off for a moment) leaves the next press
    /// alone: one the bridge takes fires, and one it doesn't (paused) keeps its release.
    func testAPressAfterALostReleaseStartsOver() {
        let h = harness(defaults())
        for step: Step in [.down, .lose, .up, .down, .up, .down, .lose, .up, .togglePause, .down, .repeatKey, .up] {
            if let failure = h.take(step) { return XCTFail("\(failure) after \(h.log)") }
        }
        XCTAssertEqual(h.emitted.actions, [playPause, playPause, playPause], "each press the bridge took")
    }

    /// With no action saved the tap doesn't ask for the keys at all, so a keyboard's F20 is
    /// never looked at, let alone swallowed.
    func testWithoutAnActionAKeyboardsF20IsNeverTouched() {
        let h = harness(defaults())
        for step: Step in [.toggleAction, .down, .repeatKey, .up, .toggleGesture, .down, .up] {
            if let failure = h.take(step) { return XCTFail("\(failure) after \(h.log)") }
        }
        XCTAssertFalse(h.tapHasKeys)
        XCTAssertEqual(h.emitted.actions, [])
    }
}

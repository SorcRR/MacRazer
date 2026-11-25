// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Where the DPI button's driver mode stands, for the Buttons page and `ButtonRemapper`, on
/// a mouse that reports the button as private keys (`RazerDevices.dpiButtonPrivateKeys`).
enum DpiDriverModeState: Equatable, Sendable {
    /// Not wanted, or no such mouse is connected: the firmware handles the button.
    case off
    /// Being read and written now.
    case engaging
    /// Read back from the mouse in driver mode: its private keys are MacRazer's to act on.
    case engaged
    /// It couldn't be set, in a plain sentence for the page (`MouseController.dpiDriverModeErrorText`).
    case unavailable(String)
}

/// Whether `ButtonRemapper` wants the DPI button's driver mode, and if it would but can't yet,
/// what is missing. Pure, so the rules are tested without a mouse or a permission.
enum DpiDriverModeNeed: Equatable, Sendable, CustomStringConvertible {
    /// Not wanted: a mouse without private keys, or no action of MacRazer's for its DPI button.
    case none
    /// Wanted, with everything it takes.
    case ready
    /// Wanted, but Accessibility is off or the event tap couldn't be made. A grant applies to
    /// the running app, and is picked up by looking again (`rechecksPermissions`).
    case accessibility
    /// Wanted, but Input Monitoring isn't granted (`IOHIDCheckAccess`), so the keys can't be
    /// seen. A grant made while MacRazer runs takes effect only once it is reopened: on macOS
    /// 26.3 `IOHIDCheckAccess` in the running process kept saying not granted after it was
    /// turned on, and the reopened app had it. So the page asks for both (`needsReopen`).
    case inputMonitoring
    /// Wanted, and Input Monitoring reads as granted, but the mouse's HID device wouldn't open
    /// in this run (`ButtonRemapper.privateKeyInputBlocked`): macOS sometimes applies the grant
    /// to a running app only once it is reopened.
    case relaunch

    /// The DPI button needs driver mode: a mouse with private keys, an action MacRazer carries
    /// out, and what carrying it out takes: the event tap (Accessibility), Input Monitoring to
    /// see the keys, asked last as it's a system call, and keys that have opened in this run.
    /// Without those the button is better left cycling DPI in the firmware than doing nothing.
    /// Input Monitoring is read in the running process (`IOHIDCheckAccess`), which may not see
    /// a grant made after it started (see `inputMonitoring`).
    init(privateKeys: Bool, action: RemapAction?, permissions: Bool, inputMonitoring: () -> Bool,
         keysBlocked: Bool) {
        if !privateKeys || action == nil {
            self = .none
        } else if !permissions {
            self = .accessibility
        } else if !inputMonitoring() {
            self = .inputMonitoring
        } else {
            self = keysBlocked ? .relaunch : .ready
        }
    }

    /// Driver mode is to be engaged.
    var wantsDriverMode: Bool { self == .ready }

    /// Only a permission stands in the way, and macOS says nothing when one is granted.
    var waitsForPermission: Bool { self == .accessibility || self == .inputMonitoring }

    /// Whether to look at the permissions every `ButtonRemapper.permissionRecheckInterval`:
    /// only while one is all that's missing and the mouse is connected (`paused` false), as
    /// driver mode can't be engaged on a mouse that's away. For Input Monitoring too, though
    /// a grant has so far needed a reopen: harmless, and it carries on by itself if macOS ever
    /// applies one to the running app. Not for `relaunch`: the grant is already there, and
    /// looking again won't apply it.
    func rechecksPermissions(paused: Bool) -> Bool { waitsForPermission && !paused }

    /// MacRazer has to be reopened before the DPI button can be seen: Input Monitoring, which
    /// a grant made while it runs needs, or a grant macOS hasn't applied to this run
    /// (`relaunch`). The status line says so, and the page offers a button that reopens it
    /// (`ButtonRemapper.reopenApp`).
    var needsReopen: Bool { self == .inputMonitoring || self == .relaunch }

    var description: String {
        switch self {
        case .none: "not needed"
        case .ready: "ready"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .relaunch: "a reopen"
        }
    }
}

/// When the DPI button's driver mode is read and written, apart from the device so the rules
/// are tested without one. `MouseController` keeps one on its device queue and runs `step`
/// whenever it has a moment (`Occasion`), and does what it says.
///
/// Driver mode is volatile: the mouse is back in normal mode after it sleeps, reconnects or
/// is switched off and on. So what was verified belongs to one connection
/// (`connectionChanged`), and a wake makes it doubtful (`doubtful`). While it is wanted, it is
/// engaged on each new connection and after each wake (a read first, so a mouse still in it
/// isn't written), and read again at most every `recheckInterval` from the poll, to put it
/// back if the mouse fell back to normal mode. A change that fails isn't retried at once:
/// the poll tries again `recheckInterval` later, at most `maxAttempts` times per connection,
/// then not until the next connection, wake or change of mind. When it isn't wanted, normal
/// mode is written back where this run may have left driver mode (`maybeSet`), and where a
/// run that crashed or was killed left it (`checkLeftover`): the mode is read once a run,
/// and written only when it reads as driver mode.
struct DpiDriverModeBook: Equatable, Sendable {
    /// How often the poll reads the mode while it is engaged, and how long a failed change
    /// waits before the poll tries it again.
    static let recheckInterval: TimeInterval = 30
    /// Failed changes on one connection before the poll stops trying.
    static let maxAttempts = 3
    /// How long a connection has answered before the mode is read for one an earlier run left
    /// (`checkLeftover`). By then `ButtonRemapper` has said whether it wants driver mode on this
    /// mouse: at launch the first reads come before it knows which mouse this is, and a mouse
    /// in driver mode then is most often one it is about to want again.
    static let leftoverCheckDelay: TimeInterval = 10

    /// What prompts a look at the mode.
    enum Occasion: Equatable, Sendable {
        /// `ButtonRemapper` started or stopped wanting it: an explicit change, tried at once.
        case wantChanged
        /// A read of the mouse went through: the poll, a connection, a wake check.
        case mouseAnswered
    }

    enum Step: Equatable, Sendable {
        case nothing
        /// Read the mode and write driver mode if it isn't (`BluetoothDevice.setDeviceMode`).
        /// It isn't known to be engaged now, so the page shows it being set up.
        case engage
        /// The same, while it is known to be engaged: a quiet check that the mouse is still in
        /// it, which puts it back if not. A read that goes unanswered changes nothing: the
        /// mouse is most likely still in the mode, and the next poll reads again.
        case recheck
        /// Write normal mode and read it back.
        case restore
        /// It isn't wanted and this run never set it: read the mode, once a run, and write
        /// normal mode back only if it reads as driver mode, which a run that crashed or was
        /// killed left there (the DPI button does nothing until then).
        case checkLeftover
    }

    /// `ButtonRemapper` needs driver mode: the DPI button has an action MacRazer carries out.
    private(set) var wanted = false
    /// When driver mode was last read back on this connection. Nil when it isn't known to be
    /// engaged now.
    private(set) var verifiedAt: TimeInterval?
    /// Changes that failed on this connection since the last success, and when the last was.
    private(set) var failures = 0
    private(set) var lastFailureAt: TimeInterval?
    /// This run may have left the mouse in driver mode: set before a write of it, or when a
    /// read finds it, and cleared once normal mode reads back. Quitting restores normal mode
    /// only then.
    private(set) var maybeSet = false
    /// When the last quiet check that went unanswered was (`recheckUnanswered`), so the next
    /// waits `recheckInterval` as one that was answered does, rather than going out at every
    /// poll for as long as the mouse doesn't answer it.
    private(set) var uncheckedSince: TimeInterval?
    /// When the mouse first answered on this connection (`answered`), for `leftoverCheckDelay`.
    private(set) var answeringSince: TimeInterval?
    /// The mode has been read once this run (`checkLeftover`, or an engage, which reads first),
    /// or this run wrote normal mode and read it back. From then on only this run can have
    /// left the mouse in driver mode, which `maybeSet` covers.
    private(set) var leftoverChecked = false

    /// What to do now.
    func step(for occasion: Occasion, now: TimeInterval) -> Step {
        if wanted {
            if let verifiedAt {
                let lastCheck = max(verifiedAt, uncheckedSince ?? verifiedAt)
                return now - lastCheck >= Self.recheckInterval ? .recheck : .nothing
            }
            return mayTry(occasion, now: now) ? .engage : .nothing
        }
        if maybeSet { return mayTry(occasion, now: now) ? .restore : .nothing }
        guard !leftoverChecked, occasion == .mouseAnswered, let answeringSince,
              now - answeringSince >= Self.leftoverCheckDelay else { return .nothing }
        return mayTry(occasion, now: now) ? .checkLeftover : .nothing
    }

    /// A first try, or a retry the poll is allowed (see the type's notes).
    private func mayTry(_ occasion: Occasion, now: TimeInterval) -> Bool {
        guard failures > 0, let lastFailureAt else { return true }
        return occasion == .mouseAnswered && failures < Self.maxAttempts
            && now - lastFailureAt >= Self.recheckInterval
    }

    /// A change of mind is a fresh start: what failed before is tried again at once.
    mutating func setWanted(_ wanted: Bool) {
        self.wanted = wanted
        failures = 0
        lastFailureAt = nil
    }

    /// Another connection to the mouse, or none: nothing verified on the last one holds.
    mutating func connectionChanged() {
        verifiedAt = nil
        uncheckedSince = nil
        answeringSince = nil
        failures = 0
        lastFailureAt = nil
    }

    /// The Mac woke, or the mouse came back: it may have lost the mode, and deserves a try.
    mutating func doubtful() { connectionChanged() }

    /// A read of the mouse went through on this connection at `now`.
    mutating func answered(at now: TimeInterval) {
        if answeringSince == nil { answeringSince = now }
    }

    /// A write of driver mode is about to go out, or a read found the mouse in it.
    mutating func mayHaveSet() { maybeSet = true }

    mutating func engaged(at now: TimeInterval) {
        verifiedAt = now
        uncheckedSince = nil
        failures = 0
        lastFailureAt = nil
        maybeSet = true
        leftoverChecked = true
    }

    /// A quiet check (`recheck`) went unanswered at `now`. Nothing else changes: the mouse is
    /// most likely still in the mode.
    mutating func recheckUnanswered(at now: TimeInterval) { uncheckedSince = now }

    /// The mode read `mode` while it isn't wanted (`checkLeftover`). Returns whether normal
    /// mode is to be written back: only when it reads as driver mode, which this run then
    /// counts as possibly set (`maybeSet`). Any other value, normal or not, is left alone.
    mutating func leftoverRead(_ mode: UInt16) -> Bool {
        failures = 0
        lastFailureAt = nil
        leftoverChecked = true
        guard mode == BLEProtocol.DeviceMode.driver.value else { return false }
        maybeSet = true
        return true
    }

    mutating func restored() {
        verifiedAt = nil
        uncheckedSince = nil
        failures = 0
        lastFailureAt = nil
        maybeSet = false
        leftoverChecked = true
    }

    mutating func failed(at now: TimeInterval) {
        verifiedAt = nil
        failures += 1
        lastFailureAt = now
    }

    /// What the page shows after `step` has run. While the change is under way it's
    /// `engaging`, which `MouseController` publishes itself.
    func state(lastError: String?) -> DpiDriverModeState {
        guard wanted else { return .off }
        if verifiedAt != nil { return .engaged }
        if failures > 0, let lastError { return .unavailable(lastError) }
        return .off
    }
}

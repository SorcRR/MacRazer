// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The serial a mouse last reported on a link (product ID + USB location), kept across
/// launches. Right after a Mac starts, the mouse can still be asleep and miss the serial read;
/// without this the app would fall back to the PID key and show none of the mouse's profiles,
/// remaps or history until the next launch.
///
/// It is a hint, not proof of which mouse it is. It picks the key the settings are loaded
/// under, and software remaps follow that key, so a second unit of the same model on the same
/// port uses the first one's settings until its own serial is read (`DeviceIdentity`'s retry,
/// within seconds of the mouse answering).
struct RememberedSerialStore {
    static let defaultsKey = "rememberedSerials"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func linkKey(pid: Int, locationID: Int) -> String {
        String(format: "%04x@%d", pid, locationID)
    }

    func serial(pid: Int, locationID: Int) -> String? {
        let saved = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]
        return saved?[Self.linkKey(pid: pid, locationID: locationID)]
    }

    func remember(_ serial: String, pid: Int, locationID: Int) {
        var saved = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        let link = Self.linkKey(pid: pid, locationID: locationID)
        guard saved[link] != serial else { return }
        saved[link] = serial
        defaults.set(saved, forKey: Self.defaultsKey)
    }
}

/// Which key a mouse's settings live under, and when to ask an unresolved serial again.
enum DeviceIdentity {
    /// How often an open link whose serial read failed is asked for it again.
    static let serialRetryInterval: TimeInterval = 10
    /// How often a link whose mouse answered without a usable serial is asked again. Rarely,
    /// not never: a mouse waking up can refuse commands or answer with zeros (the battery
    /// read sees both), and that is the very case remembered serials exist for.
    static let absentSerialRetryInterval: TimeInterval = 300

    /// The serial the mouse reported wins. Then the key this session uses on this same link (a
    /// failed read on a reconnect is not a new mouse). Then the serial last seen on this link,
    /// ahead of a session key from another link, which may be another mouse. That session key
    /// still beats the PID: it is often the same mouse, moved from its dongle to its cable.
    static func key(probed: String?, sessionKey: String?, sessionIsThisLink: Bool, remembered: String?,
                    pidKey: String) -> String {
        probed ?? (sessionIsThisLink ? sessionKey : nil) ?? remembered ?? sessionKey ?? pidKey
    }

    /// What a serial read found.
    enum SerialProbe: Equatable {
        case serial(String)
        /// The mouse answered without a usable serial: refused it, or sent blanks or zeros.
        case absent
        /// No answer (a timeout, a failed transfer): likely asleep, so worth asking again soon.
        case noAnswer
    }

    static func classify(_ result: Result<RazerReport, Error>) -> SerialProbe {
        switch result {
        case .success(let reply):
            return RazerCommands.parseSerial(reply).map(SerialProbe.serial) ?? .absent
        case .failure(HIDDevice.HIDError.commandFailed), .failure(HIDDevice.HIDError.notSupported):
            return .absent
        case .failure:
            return .noAnswer
        }
    }

    /// Whether a serial read late on an open link means reopening it. Only when it changes the
    /// key the settings are under: a reopen costs a teardown, and on Bluetooth a reconnect.
    static func reopensAfterRetry(probed: String, sessionKey: String?) -> Bool {
        probed != sessionKey
    }

    /// Whether to ask an open link for its serial again. Only while it is unknown: a link
    /// kept open because the mouse answers its battery reads otherwise stays on the fallback
    /// key for the whole session. Only every `absentSerialRetryInterval` when the mouse
    /// answered without a usable serial (`serialAbsent`): most such mice say the same each time.
    static func serialRetryDue(serialKnown: Bool, serialAbsent: Bool = false, lastAttempt: Date?, now: Date,
                               interval: TimeInterval = serialRetryInterval,
                               absentInterval: TimeInterval = absentSerialRetryInterval) -> Bool {
        guard !serialKnown else { return false }
        let interval = serialAbsent ? absentInterval : interval
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= interval
    }
}

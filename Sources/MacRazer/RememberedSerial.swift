// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The serial a mouse last reported on a link (product ID + USB location), kept across
/// launches. Right after a Mac starts, the mouse can still be asleep and miss the serial read;
/// without this the app would fall back to the PID key and show none of the mouse's profiles,
/// remaps or history until the next launch.
///
/// It is a hint, not proof of which mouse it is: it only picks the key the settings are
/// loaded and shown under. Anything written to the mouse still waits for the serial the
/// mouse reports itself (`knownSerial`), so a second unit of the same model plugged into the
/// same port never gets the first one's remaps.
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

    /// The serial the mouse reported wins. Then the key this session already uses (a failed
    /// read on a reconnect is not a new mouse). Then the serial last seen on this link. The
    /// PID only when there is none of these.
    static func key(probed: String?, sessionKey: String?, remembered: String?, pidKey: String) -> String {
        probed ?? sessionKey ?? remembered ?? pidKey
    }

    /// Whether to ask an open link for its serial again. Only while it is unknown: a link
    /// kept open because the mouse answers its battery reads otherwise stays on the fallback
    /// key for the whole session.
    static func serialRetryDue(serialKnown: Bool, lastAttempt: Date?, now: Date,
                               interval: TimeInterval = serialRetryInterval) -> Bool {
        guard !serialKnown else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= interval
    }
}

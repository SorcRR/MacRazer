// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The one tip note in Configure Buttons. It comes the first time a remapped button actually
/// fires, which is the moment the app has just saved someone a trip to Windows, and only for
/// someone with no mappings when this version first ran. Shown once, then never again.
enum RemapTip {
    enum State: String {
        /// No mapping has fired yet.
        case waiting
        /// One has: Configure Buttons shows the note the next time it's on screen.
        case due
        /// Shown, or never to be: mappings were already saved before this version.
        case done
    }

    static let stateKey = "remapTip.state"
    /// What `ButtonRemapper` saves each mouse's table under, followed by the mouse's key.
    static let mappingsPrefix = "buttonMappings-"

    static func state(_ defaults: UserDefaults) -> State {
        defaults.string(forKey: stateKey).flatMap(State.init(rawValue:)) ?? .waiting
    }

    /// Decides once, on the first run with this version: someone who already saved mappings
    /// has had the moment, so they never get the note. A table counts only with a mapping in
    /// it: clearing every button saves an empty one, and that person never had the moment
    /// either.
    static func start(_ defaults: UserDefaults) {
        guard defaults.string(forKey: stateKey) == nil else { return }
        let hasMappings = defaults.dictionaryRepresentation().contains { key, value in
            guard key.hasPrefix(mappingsPrefix), key != mappingsPrefix + "none",
                  let data = value as? Data,
                  let table = try? JSONDecoder().decode([Int: RemapAction].self, from: data) else { return false }
            return !table.isEmpty
        }
        defaults.set((hasMappings ? State.done : .waiting).rawValue, forKey: stateKey)
    }

    /// A remapped button fired. True when that makes the note due.
    static func fired(_ defaults: UserDefaults) -> Bool {
        guard state(defaults) == .waiting else { return false }
        defaults.set(State.due.rawValue, forKey: stateKey)
        return true
    }

    static func markShown(_ defaults: UserDefaults) {
        defaults.set(State.done.rawValue, forKey: stateKey)
    }
}

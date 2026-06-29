// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// A named, switchable snapshot of everything the popover lets you configure: DPI, polling rate,
/// lighting, and button remaps. The physical "profile" button on the mouse only cycles DPI
/// stages in firmware — there's no onboard multi-profile storage or button-press notification to
/// hook into, so switching profiles is an app-side action taken from the popover.
struct MouseProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var dpi: Int
    var pollRate: Int
    var brightness: Int // percent
    /// Raw value of `PopoverView`'s `Effect` enum ("Static"/"Spectrum"/"Wave"/"Off").
    var effect: String
    /// Only meaningful when `effect == "Static"`.
    var color: RGB
    var buttonMappings: [Int: RemapAction]

    init(name: String, dpi: Int, pollRate: Int, brightness: Int, effect: String, color: RGB,
         buttonMappings: [Int: RemapAction]) {
        self.id = UUID()
        self.name = name
        self.dpi = dpi
        self.pollRate = pollRate
        self.brightness = brightness
        self.effect = effect
        self.color = color
        self.buttonMappings = buttonMappings
    }

    /// One-line summary shown under a profile's name in the manage page.
    var summary: String {
        "\(dpi) DPI · \(pollRate) Hz · \(effect)"
    }
}

/// Per-device persistence for `[MouseProfile]`, following the same UserDefaults pattern as
/// `ButtonRemapper`'s mapping storage (JSON-encoded `Data` under a device-keyed string).
struct ProfileStore {
    private static func key(forDevice deviceKey: String) -> String { "profiles-\(deviceKey)" }
    private static func activeKey(forDevice deviceKey: String) -> String { "activeProfileID-\(deviceKey)" }

    static func profiles(forDevice deviceKey: String) -> [MouseProfile] {
        guard let data = UserDefaults.standard.data(forKey: key(forDevice: deviceKey)),
              let decoded = try? JSONDecoder().decode([MouseProfile].self, from: data) else { return [] }
        return decoded
    }

    static func save(_ profiles: [MouseProfile], forDevice deviceKey: String) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: key(forDevice: deviceKey))
    }

    static func activeProfileID(forDevice deviceKey: String) -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: activeKey(forDevice: deviceKey)) else { return nil }
        return UUID(uuidString: raw)
    }

    static func setActiveProfileID(_ id: UUID?, forDevice deviceKey: String) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: activeKey(forDevice: deviceKey))
        } else {
            UserDefaults.standard.removeObject(forKey: activeKey(forDevice: deviceKey))
        }
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Who peeks out, and from where. Santa and his reindeer live in the popover; elves and
/// Little Krampus in the Settings window.
public enum HolidayCharacter: String, CaseIterable, Codable, Sendable {
    case santa, reindeer, elf, krampus

    /// Points for a catch.
    public var points: Int {
        switch self {
        case .santa, .elf: 1
        case .reindeer: 2
        case .krampus: 3
        }
    }

    /// The bonus characters stay a second less than the regular one.
    var isBonus: Bool { self == .reindeer || self == .krampus }

    /// What the bubble says when it's caught.
    public var catchLine: String {
        switch self {
        case .santa: "Ho ho ho!"
        case .reindeer: "Rudolph! +2"
        case .elf: "Elf! +1"
        case .krampus: "Krampus caught! +3"
        }
    }

    /// The name VoiceOver reads for the character's button.
    /// For the score's breakdown: "3 Santa", "1 elf", "2 elves".
    func countName(_ n: Int) -> String {
        switch self {
        case .santa: "Santa"
        case .reindeer: "reindeer"
        case .elf: n == 1 ? "elf" : "elves"
        case .krampus: "Krampus"
        }
    }

    public var spokenName: String {
        switch self {
        case .santa: "Santa"
        case .reindeer: "Rudolph"
        case .elf: "An elf"
        case .krampus: "Little Krampus"
        }
    }
}

/// The place a game is played. Each has its regular character and its rarer bonus one.
public enum HolidaySurface: String, CaseIterable, Sendable {
    case popover, settings

    var regular: HolidayCharacter { self == .popover ? .santa : .elf }
    var bonus: HolidayCharacter { self == .popover ? .reindeer : .krampus }
    /// One peek in this many is the bonus character: 1 in 6 for Rudolph, 1 in 8 for Krampus.
    var bonusOneIn: Int { self == .popover ? 6 : 8 }
}

/// The game's numbers, in one place so the tests can hold them still. Agreed in the design
/// mockups: seven levels that get faster, a bonus character that's quicker still, and short
/// gaps once someone's clearly playing.
public enum HolidayGameRules {
    /// The score each level starts at.
    public static let levelThresholds = [0, 10, 25, 50, 100, 150, 200]
    /// Seconds a regular character stays out at each level, slide in and out included.
    public static let visibleSeconds: [Double] = [4, 3.2, 2.6, 2.1, 1.7, 1.4, 1.1]
    /// A bonus character stays this much less, but never under the floor: below about 0.8 s
    /// almost nobody can see it, move there and click.
    public static let bonusShorterBy = 1.0
    public static let bonusFloor = 0.8
    /// After a level-up this many peeks keep a time halfway between the old level and the new.
    public static let warmUpPeeks = 2
    /// The slide in and out, part of the visible time rather than added to it.
    public static let slideSeconds = 0.15

    /// The level for a score, 0-based.
    public static func level(for score: Int) -> Int {
        levelThresholds.lastIndex { score >= $0 } ?? 0
    }

    /// Points still needed for the next level, or nil at the top.
    public static func pointsToNextLevel(from score: Int) -> Int? {
        let level = level(for: score)
        guard level + 1 < levelThresholds.count else { return nil }
        return levelThresholds[level + 1] - score
    }

    /// How far through the current level a score is, 0 to 1. 1 at the top level.
    public static func progress(for score: Int) -> Double {
        let level = level(for: score)
        guard level + 1 < levelThresholds.count else { return 1 }
        let low = levelThresholds[level], high = levelThresholds[level + 1]
        return Double(score - low) / Double(high - low)
    }

    /// How long a character stays out.
    static func visible(_ character: HolidayCharacter, level: Int, warmingUpFrom: Int?) -> Double {
        let now = visibleSeconds[min(max(level, 0), visibleSeconds.count - 1)]
        let regular = warmingUpFrom.map { (visibleSeconds[$0] + now) / 2 } ?? now
        return character.isBonus ? max(bonusFloor, regular - bonusShorterBy) : regular
    }

    /// How long nothing peeks before the next one, as a range to pick from. Short right after
    /// a catch, and short for good once someone has more than ten points.
    static func gap(score: Int, justCaught: Bool) -> ClosedRange<Double> {
        if score > 10 { return 1...2 }
        if justCaught { return 2...3 }
        return 2...12
    }

}

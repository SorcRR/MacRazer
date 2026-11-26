// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import Combine

/// How rare a gift is.
public enum HolidayGiftRarity: String, Sendable {
    case regular, rare, veryRare
}

/// What can be inside a present. Raw values are what gets stored (and later sent to the
/// leaderboard), so they never change once shipped.
public enum HolidayGift: String, CaseIterable, Sendable {
    case socks, banana, coal
    case rubberDuck = "rubber_duck"
    case gingerbreadMouse = "gingerbread_mouse"
    case carrot, mitten, fruitcake
    case spareBattery = "spare_battery"
    case snowGlobe = "snow_globe"
    case appTip = "app_tip"
    case uglySweater = "ugly_sweater"
    case candyCane = "candy_cane"
    case hotCocoa = "hot_cocoa"
    case paperCrown = "paper_crown"
    case tangledLights = "tangled_lights"
    case wrongCable = "wrong_cable"
    case mouseScarf = "mouse_scarf"
    case pinecone
    case mousePad = "mouse_pad"
    /// One in 20 presents.
    case goldenMouse = "golden_mouse"
    /// One in 100 presents.
    case goldenChocolate = "golden_chocolate"

    public var rarity: HolidayGiftRarity {
        switch self {
        case .goldenMouse: .rare
        case .goldenChocolate: .veryRare
        default: .regular
        }
    }

    public var name: String {
        switch self {
        case .socks: "Socks"
        case .banana: "A banana"
        case .coal: "Lump of coal"
        case .rubberDuck: "Rubber duck"
        case .gingerbreadMouse: "Gingerbread mouse"
        case .carrot: "A carrot"
        case .mitten: "One mitten"
        case .fruitcake: "Fruitcake"
        case .spareBattery: "Spare battery"
        case .snowGlobe: "Snow globe"
        case .appTip: "A real tip"
        case .uglySweater: "Ugly sweater"
        case .candyCane: "Candy cane"
        case .hotCocoa: "Hot cocoa"
        case .paperCrown: "Paper crown"
        case .tangledLights: "Tangled lights"
        case .wrongCable: "The wrong cable"
        case .mouseScarf: "Tiny mouse scarf"
        case .pinecone: "Pinecone"
        case .mousePad: "Tiny mouse pad"
        case .goldenMouse: "Golden mouse"
        case .goldenChocolate: "Golden chocolate"
        }
    }

    /// The funny line under the name.
    public var line: String {
        switch self {
        case .socks: "Warm feet, steady aim."
        case .banana: "For scale."
        case .coal: "Santa saw you clicking too fast."
        case .rubberDuck: "Explain your bugs to it. It listens."
        case .gingerbreadMouse: "No cable. Slightly crunchy."
        case .carrot: "Rudolph would like it back."
        case .mitten: "The other one is in the post."
        case .fruitcake: "It has been regifted since 1998."
        case .spareBattery: "Your mouse says thank you."
        case .snowGlobe: "Shake it gently. Not the mouse."
        case .appTip: "Scroll over any slider to nudge it a step."
        case .uglySweater: "It has a reindeer on it. The nose blinks."
        case .candyCane: "Peppermint. Not a replacement cable."
        case .hotCocoa: "Keep it well away from the keyboard."
        case .paperCrown: "From a cracker. Wear it all day."
        case .tangledLights: "Good luck with that."
        case .wrongCable: "So close."
        case .mouseScarf: "Your mouse looks very cosy."
        case .pinecone: "Straight from the tree."
        case .mousePad: "For a very small mouse."
        case .goldenMouse: "One present in twenty. Click it with pride."
        case .goldenChocolate: "One present in a hundred. Don't eat it all at once."
        }
    }

    /// Drawn as an emoji: every Mac has them, and they read at any size.
    public var emoji: String {
        switch self {
        case .socks: "🧦"
        case .banana: "🍌"
        case .coal: "🪨"
        case .rubberDuck: "🦆"
        case .gingerbreadMouse: "🍪"
        case .carrot: "🥕"
        case .mitten: "🧤"
        case .fruitcake: "🍰"
        case .spareBattery: "🔋"
        case .snowGlobe: "❄️"
        case .appTip: "💡"
        case .uglySweater: "🧥"
        case .candyCane: "🍬"
        case .hotCocoa: "☕️"
        case .paperCrown: "👑"
        case .tangledLights: "✨"
        case .wrongCable: "🔌"
        case .mouseScarf: "🧣"
        case .pinecone: "🌲"
        case .mousePad: "🟩"
        case .goldenMouse: "🐭"
        case .goldenChocolate: "🍫"
        }
    }

    static var regulars: [HolidayGift] { allCases.filter { $0.rarity == .regular } }

    /// Three different gifts. Each present on its own is golden chocolate one time in 100 and
    /// a golden mouse one time in 20; otherwise a regular gift.
    static func pickThree(random: () -> Double) -> [HolidayGift] {
        var picked: [HolidayGift] = []
        while picked.count < 3 {
            let roll = random()
            var gift: HolidayGift
            if roll < 0.01 {
                gift = .goldenChocolate
            } else if roll < 0.06 {
                gift = .goldenMouse
            } else {
                gift = regular(excluding: picked, random: random)
            }
            // A rare one twice becomes a regular gift: the three are always different.
            if picked.contains(gift) { gift = regular(excluding: picked, random: random) }
            picked.append(gift)
        }
        return picked
    }

    private static func regular(excluding picked: [HolidayGift], random: () -> Double) -> HolidayGift {
        let pool = regulars.filter { !picked.contains($0) }
        let index = min(Int(random() * Double(pool.count)), pool.count - 1)
        return pool[index]
    }
}

/// The three presents under the tree. Picked the first time one is opened, kept per season, so
/// the same three are there on the 26th; gone from the popover on the 27th. They never add
/// points. For now they're picked here; the leaderboard will have the Worker pick them.
@MainActor
public final class HolidayPresents: ObservableObject {
    public static let shared = HolidayPresents(holiday: .shared)

    public static let count = 3

    /// The three gifts, once picked.
    @Published public private(set) var gifts: [HolidayGift] = []
    /// Which of the three boxes are open.
    @Published public private(set) var opened: Set<Int> = []
    /// Hidden with the card's close button; Settings brings them back.
    @Published public private(set) var hidden = false
    /// The box whose gift the strip under the scene describes.
    @Published public var featured: Int?

    private let holiday: Holiday
    private let random: () -> Double
    private var cancellables: Set<AnyCancellable> = []

    init(holiday: Holiday, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.holiday = holiday
        self.random = random
        load()
        holiday.$storageSeason.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.load() }
            .store(in: &cancellables)
        #if DEBUG
        // `MACRAZER_HOLIDAY_PRESENTS=2` opens that many boxes at once, for still renders.
        if let text = ProcessInfo.processInfo.environment["MACRAZER_HOLIDAY_PRESENTS"], let n = Int(text) {
            for box in 0..<min(n, Self.count) { _ = open(box) }
        }
        #endif
    }

    public var stage: HolidayPresentsStage? { holiday.presentsStage }

    public var allOpened: Bool { opened.count == Self.count }

    /// The gift in an open box.
    public func gift(in box: Int) -> HolidayGift? {
        guard opened.contains(box), gifts.indices.contains(box) else { return nil }
        return gifts[box]
    }

    /// Opens a box, on Christmas Day or the day after. Returns what was inside.
    @discardableResult
    public func open(_ box: Int) -> HolidayGift? {
        guard stage == .open, (0..<Self.count).contains(box), !opened.contains(box) else { return nil }
        if gifts.count != Self.count { gifts = HolidayGift.pickThree(random: random) }
        opened.insert(box)
        featured = box
        save()
        return gifts[box]
    }

    /// The card's close button, or the Settings switch.
    public func setHidden(_ hide: Bool) {
        guard hide != hidden else { return }
        if hide, holiday.stored(Bool.self, "presents.hiddenOnce") != true {
            holiday.setStored(true, "presents.hiddenOnce")
            holiday.record(.presentsHidden)
        }
        hidden = hide
        save()
    }

    private func load() {
        gifts = (holiday.stored([String].self, "presents.gifts") ?? []).compactMap(HolidayGift.init(rawValue:))
        if gifts.count != Self.count { gifts = [] }
        opened = Set(holiday.stored([Int].self, "presents.opened") ?? [])
        hidden = holiday.stored(Bool.self, "presents.hidden") ?? false
        // The strip describes an open box after a relaunch too.
        featured = opened.max()
    }

    private func save() {
        holiday.setStored(gifts.map(\.rawValue), "presents.gifts")
        holiday.setStored(opened.sorted(), "presents.opened")
        holiday.setStored(hidden, "presents.hidden")
    }
}

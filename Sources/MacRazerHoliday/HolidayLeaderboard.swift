// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import Combine

/// One row on the board.
public struct HolidayPlayer: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var score: Int
    public var counts: [HolidayCharacter: Int]
    /// The gifts opened so far, up to three.
    public var gifts: [HolidayGift]
    public var isYou: Bool

    /// Rarest first, for the icon strip.
    public var giftsRarestFirst: [HolidayGift] {
        gifts.sorted { $0.rarity.order > $1.rarity.order }
    }
}

extension HolidayGiftRarity {
    var order: Int {
        switch self {
        case .regular: 0
        case .rare: 1
        case .veryRare: 2
        }
    }
}

/// What the Worker sends back: the top of the board and how many have joined. Below
/// `HolidayLeaderboard.minimumPlayers` it sends only the count.
public struct HolidayBoard: Equatable, Sendable {
    public var playerCount: Int
    /// Best first. Empty until the board opens.
    public var players: [HolidayPlayer]
}

/// Where the board comes from. The Worker client comes with the server side; until then
/// only the debug mock exists, and without a source the leaderboard isn't shown at all.
@MainActor
protocol HolidayBoardSource {
    func board(you: HolidayPlayer?) -> HolidayBoard
}

/// The Santa leaderboard: opt in with a festive name, see the top of the board and your own
/// place. Nothing is sent before joining, and leaving deletes the row.
@MainActor
public final class HolidayLeaderboard: ObservableObject {
    public static let shared = HolidayLeaderboard(holiday: .shared, game: .shared, presents: .shared,
                                                  source: HolidayLeaderboard.debugSource())

    /// Hidden for everyone until this many have joined.
    public static let minimumPlayers = 30
    /// The rows shown above your own.
    public static let topRows = 10
    static let nameLength = 3...24

    /// The name you play under, once joined. Per season.
    @Published public private(set) var name: String?
    /// The name offered on the join card.
    @Published public var suggestedName: String
    @Published public private(set) var board: HolidayBoard?

    private let holiday: Holiday
    private let game: HolidayGame
    private let presents: HolidayPresents
    private let source: HolidayBoardSource?
    private var random: () -> Double
    private var cancellables: Set<AnyCancellable> = []

    init(holiday: Holiday, game: HolidayGame, presents: HolidayPresents, source: HolidayBoardSource?,
         random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.holiday = holiday
        self.game = game
        self.presents = presents
        self.source = source
        self.random = random
        suggestedName = HolidayNames.random(random)
        load()
        holiday.$storageSeason.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.load() }
            .store(in: &cancellables)
    }

    /// Whether the leaderboard is there to open at all: in the season, with somewhere to
    /// get the board from.
    public var isAvailable: Bool { source != nil && holiday.isFestive }

    public var joined: Bool { name != nil }

    /// The board is open once enough players have joined.
    public var isOpen: Bool { (board?.playerCount ?? 0) >= Self.minimumPlayers }

    /// From the end of Jan 6 the scores stand; until then they're still moving.
    public var isFinalDay: Bool { holiday.phase == .lastDay }

    /// Your place, 1 for the top, once joined and the board is open.
    public var rank: Int? {
        guard isOpen else { return nil }
        return board?.players.firstIndex(where: \.isYou).map { $0 + 1 }
    }

    /// The rows to show: the top ten, then yours with a gap above it if it's further down.
    public var visibleRows: [(rank: Int, player: HolidayPlayer, gapAbove: Bool)] {
        guard isOpen, let players = board?.players else { return [] }
        var rows = players.prefix(Self.topRows).enumerated().map { (rank: $0.offset + 1, player: $0.element, gapAbove: false) }
        if let rank, rank > Self.topRows {
            // Straight after the tenth there's nobody in between to leave out.
            rows.append((rank: rank, player: players[rank - 1], gapAbove: rank > Self.topRows + 1))
        }
        return rows
    }

    public func shuffleName() { suggestedName = HolidayNames.random(random) }

    /// A name that's fit to show: trimmed, 3 to 24 letters, digits, spaces, hyphens or
    /// apostrophes. Nil when it isn't. The Worker checks it again against its word list.
    public static func cleaned(_ name: String) -> String? {
        let trimmed = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard nameLength.contains(trimmed.count) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -'"))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return trimmed
    }

    /// Joins, or renames once joined. Returns false for a name that isn't fit to show.
    @discardableResult
    public func join(as proposed: String) -> Bool {
        guard isAvailable, let clean = Self.cleaned(proposed) else { return false }
        name = clean
        holiday.setStored(clean, "leaderboard.name")
        refresh()
        return true
    }

    /// Leaves the board. On the server this deletes the row; the score stays on this Mac.
    public func leave() {
        name = nil
        holiday.removeStored("leaderboard.name")
        refresh()
    }

    /// Fetches the board. Only while its page is open.
    public func refresh() {
        guard let source, isAvailable else { board = nil; return }
        board = source.board(you: you)
    }

    /// Your row as the Mac knows it.
    var you: HolidayPlayer? {
        guard let name else { return nil }
        let gifts = (0..<HolidayPresents.count).compactMap { presents.gift(in: $0) }
        return HolidayPlayer(id: "you", name: name, score: game.score, counts: game.counts, gifts: gifts, isYou: true)
    }

    private func load() {
        name = holiday.stored(String.self, "leaderboard.name")
        board = nil
    }

    /// `MACRAZER_HOLIDAY_LEADERBOARD=mock` fills the board with made-up players, for trying the
    /// page before the Worker has it; `=few` stays below the 30 the board needs. Debug only.
    static func debugSource() -> HolidayBoardSource? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["MACRAZER_HOLIDAY_LEADERBOARD"] {
        case "mock": return HolidayMockBoard(players: 128)
        case "few": return HolidayMockBoard(players: 17)
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

/// Made-up players, the same ones every time, with you slotted in by your score.
struct HolidayMockBoard: HolidayBoardSource {
    let players: Int

    func board(you: HolidayPlayer?) -> HolidayBoard {
        var rng = SeededRandom(seed: 2026)
        var rows: [HolidayPlayer] = []
        var usedNames: Set<String> = []
        for i in 0..<players {
            var name = HolidayNames.random { rng.next() }
            while usedNames.contains(name) { name = HolidayNames.random { rng.next() } }
            usedNames.insert(name)
            // A long tail: a few keen players, most with a handful of catches.
            let score = Int(620 * pow(rng.next(), 2.6)) + 1
            rows.append(HolidayPlayer(id: "p\(i)", name: name, score: score,
                                      counts: Self.counts(for: score, rng: &rng),
                                      gifts: HolidayGift.pickThree { rng.next() }.prefix(Int(rng.next() * 3.99)).map { $0 },
                                      isYou: false))
        }
        let total = players + (you == nil ? 0 : 1)
        guard total >= HolidayLeaderboard.minimumPlayers else { return HolidayBoard(playerCount: total, players: []) }
        if let you { rows.append(you) }
        rows.sort { $0.score != $1.score ? $0.score > $1.score : $0.isYou && !$1.isYou }
        return HolidayBoard(playerCount: total, players: rows)
    }

    /// Splits a score into catches the way the game hands them out.
    private static func counts(for score: Int, rng: inout SeededRandom) -> [HolidayCharacter: Int] {
        var left = score
        let krampus = Int(Double(left) * 0.04 * rng.next()) / 3
        left -= krampus * 3
        let reindeer = Int(Double(left) * 0.25 * rng.next()) / 2
        left -= reindeer * 2
        let elves = Int(Double(left) * 0.3 * rng.next())
        left -= elves
        return [.santa: left, .reindeer: reindeer, .elf: elves, .krampus: krampus].filter { $0.value > 0 }
    }
}

/// Festive names: an adjective and a noun, "Frosty Gingerbread".
enum HolidayNames {
    static let adjectives = [
        "Frosty", "Jolly", "Merry", "Snowy", "Twinkly", "Cosy", "Sparkly", "Toasty", "Glittery", "Fuzzy",
        "Peppermint", "Sleepy", "Speedy", "Tinsel", "Velvet", "Starry", "Crunchy", "Rosy", "Nimble", "Bouncy",
    ]
    static let nouns = [
        "Gingerbread", "Snowflake", "Reindeer", "Sleigh", "Mitten", "Snowman", "Pinecone", "Candy Cane",
        "Stocking", "Sprout", "Pudding", "Bauble", "Cracker", "Icicle", "Penguin", "Chestnut", "Robin",
        "Snowball", "Cocoa", "Jingle Bell",
    ]

    static func random(_ random: () -> Double) -> String {
        let a = adjectives[min(Int(random() * Double(adjectives.count)), adjectives.count - 1)]
        let n = nouns[min(Int(random() * Double(nouns.count)), nouns.count - 1)]
        return "\(a) \(n)"
    }
}

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

/// What the Worker sends back: how many have joined, and from 30 the top ten, plus your own
/// row and place when you're joined. Below `HolidayLeaderboard.minimumPlayers` only the count.
public struct HolidayBoard: Equatable, Sendable {
    public var playerCount: Int
    /// Best first. Empty until the board opens.
    public var top: [HolidayPlayer] = []
    public var you: HolidayPlayer?
    public var yourRank: Int?
}

/// The Santa leaderboard: opt in with a festive name, see the top of the board and your own
/// place. Nothing is sent before joining; then the score goes every few minutes, and leaving
/// deletes the row. The score always lives on the Mac first: the game works the same without
/// joining, and offline.
@MainActor
public final class HolidayLeaderboard: ObservableObject {
    public static let shared = HolidayLeaderboard(holiday: .shared, game: .shared, presents: .shared,
                                                  source: HolidayLeaderboard.debugSource())

    /// Hidden for everyone until this many have joined.
    public static let minimumPlayers = 30
    /// The rows shown above your own.
    public static let topRows = 10
    static let nameLength = 3...24
    /// How often a changed score goes to the Worker, on the update check's own rhythm: at
    /// launch, every three hours, and at quit. The Worker runs on Cloudflare's free plan and
    /// every stored score is a few database writes. The board's page sends one at once when it
    /// opens, so your own row is current whenever you look.
    static let syncInterval: TimeInterval = 3 * 60 * 60

    /// The name you play under, once joined. Per season.
    @Published public private(set) var name: String?
    /// The name offered on the join card.
    @Published public var suggestedName: String
    @Published public private(set) var board: HolidayBoard?
    /// A join or rename on its way.
    @Published public private(set) var joining = false
    /// What went wrong with the last join, in words for the page.
    @Published public private(set) var problem: String?
    /// The last try to fetch the board didn't reach the Worker: no connection, most likely.
    @Published public private(set) var boardUnreachable = false

    private let holiday: Holiday
    private let game: HolidayGame
    private let presents: HolidayPresents
    private var source: HolidayBoardSource?
    private var random: () -> Double
    private var cancellables: Set<AnyCancellable> = []
    private var syncing = false
    /// When everything waiting last reached the Worker, for the three-hour rhythm.
    private var lastSynced: Date?

    init(holiday: Holiday, game: HolidayGame, presents: HolidayPresents, source: HolidayBoardSource?,
         random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.holiday = holiday
        self.game = game
        self.presents = presents
        self.source = source
        self.random = random
        suggestedName = HolidayNames.random(random)
        load()
        presents.onOpened = { [weak self] in self?.presentsChanged() }
        holiday.$storageSeason.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.load() }
            .store(in: &cancellables)
    }

    /// The app hands over the Worker and the Mac's hardware UUID at launch. Without either,
    /// or with the debug mock in use, nothing changes.
    public func configure(base: URL?, hardwareUUID: String?, send: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        guard source == nil, let base, let hardwareUUID, !hardwareUUID.isEmpty else { return }
        source = HolidaySantaClient(base: base, key: HolidayPlayerKey.make(fromHardwareUUID: hardwareUUID), send: send)
        objectWillChange.send()
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
    public var rank: Int? { isOpen ? board?.yourRank : nil }

    /// The rows to show: the top ten, then yours with a gap above it if it's further down.
    public var visibleRows: [(rank: Int, player: HolidayPlayer, gapAbove: Bool)] {
        guard isOpen, let board else { return [] }
        let me = board.you.map(current)
        var top = board.top.map(current)
        // Caught up into the top ten since the Worker last stored your score: in you go.
        if let me, let rank = board.yourRank, rank <= Self.topRows, !top.contains(where: \.isYou) {
            top.append(me)
        }
        // Best first by the scores as they are now; equal scores keep the Worker's order.
        top = top.enumerated().sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
        top = Array(top.prefix(Self.topRows))
        // Players on the same score share a place, as the Worker counts them.
        var rows = top.map { player in (rank: 1 + top.filter { $0.score > player.score }.count, player: player, gapAbove: false) }
        if let me, let rank = board.yourRank, !top.contains(where: \.isYou) {
            // Straight after the tenth there's nobody in between to leave out.
            rows.append((rank: rank, player: me, gapAbove: rank > top.count + 1))
        }
        return rows
    }

    /// Your own row as it is on this Mac right now: the Worker's copy can be a few catches
    /// behind until the next send.
    private func current(_ player: HolidayPlayer) -> HolidayPlayer {
        guard player.isYou else { return player }
        var me = player
        if game.score > me.score {
            me.score = game.score
            me.counts = game.counts
        }
        let gifts = (0..<HolidayPresents.count).compactMap { presents.gift(in: $0) }
        if gifts.count > me.gifts.count { me.gifts = gifts }
        return me
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

    /// Joins, or renames once joined. True once the Worker has it. After a reinstall the
    /// Worker's catches come back, where they're more than this Mac has.
    @discardableResult
    public func join(as proposed: String) async -> Bool {
        guard isAvailable, let source, !joining else { return false }
        guard let clean = Self.cleaned(proposed) else {
            problem = "3 to 24 letters, numbers and spaces."
            return false
        }
        joining = true
        problem = nil
        defer { joining = false }
        do {
            let reply = try await source.join(name: clean)
            holiday.removeStored("leaderboard.leaving")
            name = reply.name
            holiday.setStored(reply.name, "leaderboard.name")
            game.adopt(reply.counts)
            // What the Worker has: the score goes again only when it's grown past that.
            holiday.setStored(HolidayLeaderboard.points(reply.counts), "leaderboard.sent")
            await sync()
            await refreshNow()
            return true
        } catch let error as HolidaySantaError {
            problem = Self.words(for: error)
            return false
        } catch {
            problem = Self.words(for: .unavailable)
            return false
        }
    }

    /// Leaves the board. The row on the Worker is deleted (tried again until it is); the
    /// score stays on this Mac.
    public func leave() {
        guard joined else { return }
        name = nil
        holiday.removeStored("leaderboard.name")
        forgetPresentsSent()
        holiday.setStored(true, "leaderboard.leaving")
        board = nil
        Task { await sync() }
    }

    /// Fetches the board. Only while its page is open.
    public func refresh() {
        Task { await refreshNow() }
    }

    func refreshNow() async {
        guard let source, isAvailable else { board = nil; return }
        do {
            board = try await source.board(you: you)
            boardUnreachable = false
        } catch {
            boardUnreachable = true
        }
    }

    /// Sends what's waiting: a leave, a grown score, the presents. With the update check (at
    /// launch, every three hours, at quit) and when the page opens. Failures are quiet and
    /// tried again next time.
    func sync() async {
        // A leave still waiting goes out in the rest of January too: the Worker takes one any time.
        guard let source, !syncing, holiday.storageYear != nil else { return }
        syncing = true
        defer { syncing = false }
        if holiday.stored(Bool.self, "leaderboard.leaving") == true {
            do {
                try await source.leave()
                holiday.removeStored("leaderboard.leaving")
            } catch {
                return
            }
        }
        guard joined, isAvailable else { lastSynced = holiday.now(); return }
        if hasScoreToSend {
            let counts = game.counts
            do {
                // What the Worker stored, not what went: it keeps one score every five minutes
                // and answers the older one in between, so a score it didn't take goes again
                // next time.
                let stored = try await source.score(counts)
                holiday.setStored(stored, "leaderboard.sent")
                lastSynced = holiday.now()
            } catch HolidaySantaError.notJoined {
                // Deleted on the Worker (by the admin): this Mac isn't on the board any more.
                name = nil
                holiday.removeStored("leaderboard.name")
                forgetPresentsSent()
            } catch {
                // Not reached: still due, so the next update tick tries again.
            }
        } else {
            lastSynced = holiday.now()
        }
        await syncPresents()
    }

    private var hasScoreToSend: Bool { game.score != holiday.stored(Int.self, "leaderboard.sent") ?? 0 }

    /// Something to tell the Worker: a leave, or a score it hasn't stored.
    public var hasSomethingToSend: Bool {
        source != nil && holiday.storageYear != nil
            && (holiday.stored(Bool.self, "leaderboard.leaving") == true || (joined && isAvailable && hasScoreToSend))
    }

    /// At launch, like the update check: unthrottled.
    public func syncAtLaunch() {
        Task { await sync() }
    }

    /// On the update check's tick (every 15 minutes, on wake, when the network comes back,
    /// when the popover opens): sends only when three hours have passed since the last time.
    public func syncIfDue() {
        guard isDue else { return }
        Task { await sync() }
    }

    var isDue: Bool {
        guard let lastSynced else { return true }
        return holiday.now().timeIntervalSince(lastSynced) >= Self.syncInterval
    }

    /// At quit: what's waiting, given at most `seconds`. Calls `done` either way.
    public func syncBeforeQuit(within seconds: Double = 2, done: @escaping @MainActor () -> Void) {
        let finished = Task { await sync() }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            finished.cancel()
        }
        Task {
            await finished.value
            done()
        }
    }

    /// Dec 25 and 26 once joined: the Worker picks the three presents, so the board shows
    /// what was really inside. Taken while no box is open yet; boxes opened go back to it.
    func syncPresents() async {
        guard let source, joined, presents.stage == .open else { return }
        // Only when there's something to say: the Worker's picks not here yet, or a box opened
        // since it last heard. Not on every tick.
        let sent = Set(holiday.stored([Int].self, "leaderboard.presentsSent") ?? [])
        let picked = holiday.stored(Bool.self, "leaderboard.presentsPicked") == true
        guard !picked || presents.opened != sent else { return }
        guard let reply = try? await source.presents(opened: presents.opened) else { return }
        presents.adopt(reply.gifts)
        holiday.setStored(true, "leaderboard.presentsPicked")
        holiday.setStored(reply.opened.sorted(), "leaderboard.presentsSent")
    }

    /// A new row on the Worker (after leaving) gets presents of its own.
    private func forgetPresentsSent() {
        holiday.removeStored("leaderboard.presentsPicked")
        holiday.removeStored("leaderboard.presentsSent")
    }

    /// The page came or went.
    public func setPageVisible(_ visible: Bool) {
        if visible { syncThenRefresh() }
    }

    /// For the page: send what's waiting, then fetch the board, so it shows the newest score.
    public func syncThenRefresh() {
        Task {
            await sync()
            await refreshNow()
        }
    }

    /// For the presents card: a box was opened, or the card appeared.
    public func presentsChanged() {
        guard joined else { return }
        Task { await syncPresents() }
    }

    /// Your row as the Mac knows it.
    var you: HolidayPlayer? {
        guard let name else { return nil }
        let gifts = (0..<HolidayPresents.count).compactMap { presents.gift(in: $0) }
        return HolidayPlayer(id: "you", name: name, score: game.score, counts: game.counts, gifts: gifts, isYou: true)
    }

    static func points(_ counts: [HolidayCharacter: Int]) -> Int {
        counts.reduce(0) { $0 + $1.key.points * $1.value }
    }

    static func words(for error: HolidaySantaError) -> String {
        switch error {
        case .badName: "That name isn't allowed. Try another one."
        case .seasonClosed: "This season's board is closed."
        case .busy: "The leaderboard is busy. Try again in a minute."
        case .notJoined, .notChristmas, .unavailable: "Couldn't reach the leaderboard. Try again in a moment."
        }
    }

    private func load() {
        name = holiday.stored(String.self, "leaderboard.name")
        board = nil
    }

    /// For still renders: joined as `name`, with nothing sent.
    public func previewJoin(_ name: String) {
        self.name = name
        previewBoard()
    }

    /// For still renders: the mock board filled in at once, without waiting on a task.
    public func previewBoard() {
        if let mock = source as? HolidayMockBoard { board = mock.make(you: you) }
    }

    /// `MACRAZER_HOLIDAY_LEADERBOARD=mock` fills the board with made-up players, for trying the
    /// page without the Worker; `=few` stays below the 30 the board needs. Debug only.
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

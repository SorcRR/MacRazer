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

/// What the Worker sends back: how many have joined and the top ten, plus your own row and
/// place when you're joined.
public struct HolidayBoard: Equatable, Sendable {
    public var playerCount: Int
    /// Best first. Empty until someone joins.
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
    /// The board's last answer was "paused" (too much traffic): the page says it's taking a break.
    @Published public private(set) var paused = false
    /// When a send was last told the board is paused. For three hours from then nothing but a
    /// leave goes, at launch, at quit or on the page either: only the page's fetch of the board,
    /// which says when it's back. Kept across a relaunch.
    private var pausedAt: Date? {
        didSet {
            guard pausedAt != oldValue else { return }
            if let pausedAt { holiday.setStored(pausedAt, "leaderboard.pausedAt") } else { holiday.removeStored("leaderboard.pausedAt") }
            scheduleBreakEnd()
        }
    }
    /// Redraws once the break is over, so the presents card's note goes with it.
    private var breakEnd: Task<Void, Never>?

    private let holiday: Holiday
    private let game: HolidayGame
    private let presents: HolidayPresents
    private var source: HolidayBoardSource?
    private var random: () -> Double
    private var cancellables: Set<AnyCancellable> = []
    /// The sync running now, if any (`sync()`).
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = 0
    /// A presents request on its way, and whether another was asked for meanwhile.
    private var presentsSyncing = false
    private var presentsAgain = false
    /// When everything waiting last reached the Worker, for the three-hour rhythm.
    private var lastSynced: Date?
    /// When a score last went, to tell the Worker's five-minute wait from its other refusals.
    private var lastScoreSent: Date?
    /// The Worker keeps one score every five minutes (`MIN_MINUTES_BETWEEN` in src/santa.ts).
    static let workerScoreGap: TimeInterval = 5 * 60

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

    /// Leaving is always possible while there's a row to delete: all season, through the
    /// rest of January when the board stands, and with the decorations switched off remotely.
    public var canLeave: Bool { joined && source != nil && holiday.storageYear != nil }

    /// Someone is on the board: from the first player who joins.
    public var hasPlayers: Bool { !(board?.top.isEmpty ?? true) || board?.you != nil }

    /// From the end of Jan 6 the scores stand; until then they're still moving.
    public var isFinalDay: Bool { holiday.phase == .lastDay }

    /// Your place, 1 for the top, once joined.
    public var rank: Int? { board?.yourRank }

    /// The rows to show: the top ten, then yours with a gap above it if it's further down.
    public var visibleRows: [(rank: Int, player: HolidayPlayer, gapAbove: Bool)] {
        guard let board else { return [] }
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
    /// A letter may carry accents, but not a stack of them that would spill over other rows.
    public static func cleaned(_ name: String) -> String? {
        let trimmed = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .precomposedStringWithCanonicalMapping
        guard nameLength.contains(trimmed.count) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -'"))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        guard trimmed.allSatisfy({ $0.unicodeScalars.count <= maxScalarsPerLetter }) else { return nil }
        return trimmed
    }

    /// A letter and up to two marks: enough for any language's accents once composed.
    static let maxScalarsPerLetter = 3

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
        // A leave still waiting goes first. Sent after the join, it would delete the new row.
        if leavePending { await sync() }
        // Not sent by now (no connection): the join keeps the old row instead, so no sync
        // may send the leave while the join is on its way. It's put back if the join fails.
        let wasLeaving = leavePending
        holiday.removeStored("leaderboard.leaving")
        do {
            let reply = try await source.join(name: clean)
            // Taken, so the board isn't paused any more.
            pausedAt = nil
            paused = false
            name = reply.name
            holiday.setStored(reply.name, "leaderboard.name")
            game.adopt(reply.counts)
            // What the Worker has: the score goes again only when it's grown past that.
            holiday.setStored(HolidayLeaderboard.points(reply.counts), "leaderboard.sent")
            await sync()
            await refreshNow()
            return true
        } catch {
            if wasLeaving { holiday.setStored(true, "leaderboard.leaving") }
            problem = Self.words(for: error as? HolidaySantaError ?? .unavailable)
            return false
        }
    }

    private var leavePending: Bool { holiday.stored(Bool.self, "leaderboard.leaving") == true }

    /// Leaves the board. The row on the Worker is deleted (tried again until it is); the
    /// score stays on this Mac.
    public func leave() {
        guard joined else { return }
        name = nil
        holiday.removeStored("leaderboard.name")
        forgetPresentsSent()
        holiday.setStored(true, "leaderboard.leaving")
        // The page shows "Loading" until the board answers without you.
        board = nil
        syncThenRefresh()
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
            paused = false
            pausedAt = nil
        } catch HolidaySantaError.paused {
            board = nil
            boardUnreachable = false
            paused = true
        } catch {
            // Not a pause this time: the page says there's no connection instead.
            boardUnreachable = true
            paused = false
        }
    }

    /// The board was paused less than three hours ago: the score and the presents wait.
    var onBreak: Bool {
        guard let pausedAt else { return false }
        return holiday.now().timeIntervalSince(pausedAt) < Self.syncInterval
    }

    private func scheduleBreakEnd() {
        breakEnd?.cancel()
        objectWillChange.send()
        guard let pausedAt else { return }
        let left = Self.syncInterval - holiday.now().timeIntervalSince(pausedAt)
        guard left > 0 else { return }
        breakEnd = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(left + 1))) != nil else { return }
            self?.objectWillChange.send()
        }
    }

    private func pausedOnSend() {
        paused = true
        pausedAt = holiday.now()
        lastSynced = holiday.now()
    }

    /// Dec 25 and 26, once joined: why the boxes still wrapped won't show on the board, if they
    /// won't. The presents card says so.
    public enum PresentsOffBoard: Equatable { case onBreak, macPicks }

    public var presentsOffBoard: PresentsOffBoard? {
        guard joined, presents.stage == .open, presents.opened.count < HolidayPresents.count else { return nil }
        let picks = (holiday.stored([String].self, "leaderboard.presentsGifts") ?? []).compactMap(HolidayGift.init(rawValue:))
        // The Worker's picks came after a box was opened on the Mac's: the rest stay the Mac's too.
        if picks.count == HolidayPresents.count { return presents.gifts == picks ? nil : .macPicks }
        // No picks yet, and none coming during the break: a box opened now won't show.
        return onBreak ? .onBreak : nil
    }

    /// Sends what's waiting: a leave, a grown score, the presents. With the update check (at
    /// launch, every three hours, at quit) and when the page opens. Failures are quiet and
    /// tried again next time.
    ///
    /// One at a time, in order: a call while one runs waits for it and then runs too, so a
    /// leave set meanwhile still goes, and nothing (a join above all) overtakes it.
    func sync() async {
        while let running = syncTask {
            await Self.wait(for: running)
            if Task.isCancelled { return }
        }
        syncGeneration += 1
        let generation = syncGeneration
        let task = Task { [weak self] in
            await self?.syncNow()
            // Cleared before anyone waiting on it resumes, so the next one can start.
            if let self, self.syncGeneration == generation { self.syncTask = nil }
        }
        syncTask = task
        await Self.wait(for: task)
    }

    /// Waits for `task`, and cancels it if the waiter is cancelled: the quit's time limit.
    private static func wait(for task: Task<Void, Never>) async {
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func syncNow() async {
        // A leave still waiting goes out in the rest of January too: the Worker takes one any time.
        guard let source, holiday.storageYear != nil else { return }
        if leavePending {
            do {
                try await source.leave()
                holiday.removeStored("leaderboard.leaving")
            } catch {
                return
            }
        }
        guard joined, isAvailable else { lastSynced = holiday.now(); return }
        // Paused for traffic: nothing more until three hours have passed or the board is back.
        if onBreak { return }
        if hasScoreToSend {
            let counts = game.counts
            let before = holiday.stored(Int.self, "leaderboard.sent") ?? 0
            let previous = lastScoreSent
            lastScoreSent = holiday.now()
            do {
                // What the Worker stored, not what went: it keeps one score every five minutes
                // and answers the older one in between, so a score it didn't take goes again
                // next time.
                let stored = try await source.score(counts)
                holiday.setStored(stored, "leaderboard.sent")
                // Less than sent: still due on the next update tick, rather than three hours
                // on, while that can help. It can within five minutes of the last score (the
                // Worker's wait), or when it took some of it (it lets a score grow only so fast,
                // so a big one catches up over a few sends). Taking none otherwise means its
                // daily limit: back to the three-hour rhythm.
                let short = stored < HolidayLeaderboard.points(counts)
                let throttled = previous.map { holiday.now().timeIntervalSince($0) < Self.workerScoreGap } ?? false
                lastSynced = short && (stored > before || throttled) ? nil : holiday.now()
            } catch HolidaySantaError.paused {
                // Paused for traffic: wait the full three hours, not the next tick, and send
                // no presents either. The score keeps counting here and goes once it's back.
                pausedOnSend()
                return
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
            && (leavePending || (joined && isAvailable && !onBreak && hasScoreToSend))
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

    /// How long the boxes wait for the Worker's picks before opening on the Mac's own.
    static let presentsHold: Double = 3

    /// Dec 25 and 26 once joined: the Worker picks the three presents, so the board shows
    /// what was really inside. Taken while no box is open yet. A box goes back to the Worker
    /// only when it shows the Worker's own pick: one opened on the Mac's pick (offline, before
    /// joining, or before the picks came) stays off the board rather than showing another
    /// gift there. Your own row still shows it, from this Mac.
    func syncPresents() async {
        // One request at a time; a box opened meanwhile goes once it's back.
        guard !presentsSyncing else { presentsAgain = true; return }
        presentsSyncing = true
        defer { presentsSyncing = false }
        repeat {
            presentsAgain = false
            await syncPresentsOnce()
        } while presentsAgain
    }

    private func syncPresentsOnce() async {
        guard let source, joined, presents.stage == .open, !onBreak else { return }
        var picks = (holiday.stored([String].self, "leaderboard.presentsGifts") ?? []).compactMap(HolidayGift.init(rawValue:))
        if picks.count != HolidayPresents.count {
            // The boxes wait for the answer, a few seconds at most, so the first one opened
            // already holds the Worker's pick.
            if presents.opened.isEmpty { presents.awaitingPicks = true }
            let release = Task { [weak self] in
                // Cancelled once the answer is in: then a later request may hold them again.
                guard (try? await Task.sleep(for: .seconds(Self.presentsHold))) != nil else { return }
                self?.presents.awaitingPicks = false
            }
            let reply: HolidayPresentsReply?
            do {
                reply = try await source.presents(opened: [])
            } catch HolidaySantaError.paused {
                pausedOnSend()
                reply = nil
            } catch {
                reply = nil
            }
            release.cancel()
            presents.awaitingPicks = false
            guard let reply, reply.gifts.count == HolidayPresents.count else { return }
            picks = reply.gifts
            holiday.setStored(picks.map(\.rawValue), "leaderboard.presentsGifts")
            presents.adopt(picks)
        }
        guard presents.gifts == picks else { return }
        // Only when a box opened since the Worker last heard. Not on every tick.
        let sent = Set(holiday.stored([Int].self, "leaderboard.presentsSent") ?? [])
        guard !sent.isSuperset(of: presents.opened) else { return }
        do {
            let reply = try await source.presents(opened: presents.opened)
            holiday.setStored(reply.opened.sorted(), "leaderboard.presentsSent")
        } catch HolidaySantaError.paused {
            pausedOnSend()
        } catch {
            // Not reached: goes with the next sync, or the next box opened.
        }
    }

    /// A new row on the Worker (after leaving) gets presents of its own.
    private func forgetPresentsSent() {
        holiday.removeStored("leaderboard.presentsGifts")
        holiday.removeStored("leaderboard.presentsSent")
    }

    /// The page came or went.
    public func setPageVisible(_ visible: Bool) {
        if visible { syncThenRefresh() }
    }

    /// For the page: send what's waiting, then fetch the board, so it shows the newest score.
    public func syncThenRefresh() {
        Task { await syncThenRefreshNow() }
    }

    func syncThenRefreshNow() async {
        await sync()
        let wasOnBreak = onBreak
        await refreshNow()
        // The board is back: what waited through the pause goes now, not hours from now.
        if wasOnBreak && !onBreak { await sync() }
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
        case .paused: "The leaderboard is taking a break. Try again later."
        case .notJoined, .notChristmas, .unavailable: "Couldn't reach the leaderboard. Try again in a moment."
        }
    }

    private func load() {
        name = holiday.stored(String.self, "leaderboard.name")
        pausedAt = holiday.stored(Date.self, "leaderboard.pausedAt")
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
    /// page without the Worker; `=few` has 4 players and `=empty` none yet. Debug only.
    static func debugSource() -> HolidayBoardSource? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["MACRAZER_HOLIDAY_LEADERBOARD"] {
        case "mock": return HolidayMockBoard(players: 128)
        case "few": return HolidayMockBoard(players: 4)
        case "empty": return HolidayMockBoard(players: 0)
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

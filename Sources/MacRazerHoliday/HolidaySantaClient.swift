// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import CryptoKit

/// The leaderboard's player key: an HMAC of the hardware UUID with a key of its own, so the
/// same Mac keeps its row after a reinstall and the value can't be matched with the usage
/// stats ID (made with a different key). 64 lowercase hex digits, as the Worker takes it.
/// Never shown and never stored; the Worker keeps only a SHA-256 of it.
enum HolidayPlayerKey {
    private static let key = SymmetricKey(data: Data("MacRazer leaderboard v1".utf8))

    static func make(fromHardwareUUID uuid: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(uuid.uppercased().utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

/// What can go wrong talking to the leaderboard. The page says something only for a name
/// that isn't allowed or a season that's over; the rest is tried again later.
public enum HolidaySantaError: Error, Equatable, Sendable {
    case badName
    case seasonClosed
    case notJoined
    case notChristmas
    /// Too many requests, or the day's limit: try again later.
    case busy
    /// No network, or the Worker is down.
    case unavailable
}

/// The answer to joining: the name as the board shows it (an admin's festive one, if it was
/// renamed) and what's stored, so a reinstalled Mac gets its score back.
public struct HolidayJoinReply: Equatable, Sendable {
    public var name: String
    public var counts: [HolidayCharacter: Int]
}

/// The three presents as the Worker picked them, and which boxes it has as open.
public struct HolidayPresentsReply: Equatable, Sendable {
    public var gifts: [HolidayGift]
    public var opened: Set<Int>
}

/// Where the board comes from: the Worker, or in a debug build the mock. Without one the
/// leaderboard isn't shown at all.
@MainActor
protocol HolidayBoardSource: AnyObject {
    func join(name: String) async throws -> HolidayJoinReply
    /// The counts so far. Answers the score as stored, which may be lower: the Worker cuts
    /// growth the game couldn't have given.
    func score(_ counts: [HolidayCharacter: Int]) async throws -> Int
    func leave() async throws
    /// The board, with your own row and place when `you` is joined.
    func board(you: HolidayPlayer?) async throws -> HolidayBoard
    /// Dec 25 and 26: the three presents, picked once on the Worker. `opened` adds boxes.
    func presents(opened: Set<Int>) async throws -> HolidayPresentsReply
}

/// The Worker's `/v1/santa/*` (src/santa.ts in macrazer-worker). Every call is a POST with
/// JSON, the key only ever in the body; the board's GET is used when not joined.
@MainActor
final class HolidaySantaClient: HolidayBoardSource {
    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    private let base: URL
    private let key: String
    private let send: Send

    init(base: URL, key: String, send: @escaping Send) {
        self.base = base
        self.key = key
        self.send = send
    }

    func join(name: String) async throws -> HolidayJoinReply {
        let reply = try await post("join", ["key": key, "name": name])
        return HolidayJoinReply(name: reply["name"] as? String ?? name, counts: Self.counts(reply["counts"]))
    }

    func score(_ counts: [HolidayCharacter: Int]) async throws -> Int {
        let total = counts.reduce(0) { $0 + $1.key.points * $1.value }
        let reply = try await post("score", ["key": key, "score": total, "counts": Self.json(counts)])
        return reply["score"] as? Int ?? total
    }

    func leave() async throws {
        _ = try await post("leave", ["key": key])
    }

    func board(you: HolidayPlayer?) async throws -> HolidayBoard {
        let reply: [String: Any]
        if let you {
            // Your score now: the Worker places you by it in this answer, and never stores it.
            reply = try await post("board", ["key": key, "score": you.score])
        } else {
            reply = try await get("board")
        }
        let top = (reply["players"] as? [[String: Any]] ?? []).compactMap { Self.player($0, isYou: false) }
        var board = HolidayBoard(playerCount: reply["playerCount"] as? Int ?? 0, top: top, you: nil, yourRank: nil)
        if let row = reply["you"] as? [String: Any], var me = Self.player(row, isYou: true) {
            board.yourRank = row["rank"] as? Int
            // Your own row in the top ten is you too.
            board.top = board.top.map { $0.id == me.id ? me : $0 }
            me.isYou = true
            board.you = me
        }
        return board
    }

    func presents(opened: Set<Int>) async throws -> HolidayPresentsReply {
        var body: [String: Any] = ["key": key]
        if !opened.isEmpty { body["opened"] = opened.sorted() }
        let reply = try await post("presents", body)
        let gifts = (reply["gifts"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(HolidayGift.init(rawValue:)) }
        return HolidayPresentsReply(gifts: gifts, opened: Set(reply["opened"] as? [Int] ?? []))
    }

    // MARK: Requests

    private func url(_ route: String) -> URL { base.appendingPathComponent("v1/santa/\(route)") }

    private func post(_ route: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url(route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await answer(request)
    }

    private func get(_ route: String) async throws -> [String: Any] {
        try await answer(URLRequest(url: url(route)))
    }

    private func answer(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            throw HolidaySantaError.unavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200..<300).contains(status) { return json }
        throw Self.error(status: status, code: json["error"] as? String)
    }

    static func error(status: Int, code: String?) -> HolidaySantaError {
        switch (status, code) {
        case (400, "bad_name"): .badName
        case (410, _): .seasonClosed
        case (404, "not_joined"): .notJoined
        case (409, _): .notChristmas
        case (429, _): .busy
        default: .unavailable
        }
    }

    // MARK: Shapes

    static func json(_ counts: [HolidayCharacter: Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: HolidayCharacter.allCases.map { ($0.rawValue, counts[$0] ?? 0) })
    }

    static func counts(_ value: Any?) -> [HolidayCharacter: Int] {
        let raw = value as? [String: Int] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in HolidayCharacter(rawValue: k).map { ($0, v) } })
    }

    static func player(_ row: [String: Any], isYou: Bool) -> HolidayPlayer? {
        guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
        let gifts = (row["gifts"] as? [String] ?? []).compactMap(HolidayGift.init(rawValue:))
        return HolidayPlayer(id: id, name: name, score: row["score"] as? Int ?? 0, counts: counts(row["counts"]),
                             gifts: gifts, isYou: isYou)
    }
}

/// Made-up players, the same ones every time, with you slotted in by your score. Debug only:
/// `MACRAZER_HOLIDAY_LEADERBOARD=mock` (128 players), `few` (4) or `empty` (none).
@MainActor
final class HolidayMockBoard: HolidayBoardSource {
    let players: Int
    private var joinedName: String?
    private var stored: [HolidayCharacter: Int] = [:]

    init(players: Int) { self.players = players }

    func join(name: String) async throws -> HolidayJoinReply {
        joinedName = name
        return HolidayJoinReply(name: name, counts: stored)
    }

    func score(_ counts: [HolidayCharacter: Int]) async throws -> Int {
        stored = counts
        return counts.reduce(0) { $0 + $1.key.points * $1.value }
    }

    func leave() async throws { joinedName = nil; stored = [:] }

    func presents(opened: Set<Int>) async throws -> HolidayPresentsReply { throw HolidaySantaError.notChristmas }

    func board(you: HolidayPlayer?) async throws -> HolidayBoard { make(you: you) }

    func make(you: HolidayPlayer?) -> HolidayBoard {
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
        if let you { rows.append(you) }
        rows.sort { $0.score != $1.score ? $0.score > $1.score : $0.isYou && !$1.isYou }
        let rank = rows.firstIndex(where: \.isYou).map { $0 + 1 }
        return HolidayBoard(playerCount: total, top: Array(rows.prefix(HolidayLeaderboard.topRows)),
                            you: you, yourRank: rank)
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

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The anonymous daily count: which mouse models this Mac has connected today, and what its
/// owner says about usage stats (yes, no, not asked yet) with any change since the last count.
/// The same request as the update check, with no ID for the Mac (see `WorkerEndpoint.releases`),
/// so the reports page can count mice in use and how many people turn sharing off or back on.
///
/// The mice used to go with the update check itself, which missed most of them. The check at
/// launch runs before the controller has found the mouse, and the next one is three hours
/// away, so a Mac used for an afternoon, or whose wireless mouse was asleep at those moments,
/// was never counted. Now a count goes out as soon as there's something new to say: the first
/// time each UTC day (the Worker's day), for a mouse not sent yet that day, and for a changed
/// answer. A failed send is silent and tried again on the app's 15-minute tick.
@MainActor
final class AnonymousCountReporter {
    typealias Fetch = (URL) async throws -> (Data, URLResponse)

    /// The mice connected now. Set by the app delegate, which knows the controller.
    var connectedMice: () -> [UsagePing.Mouse] = { [] }
    /// The usage stats answer now, and the changes not sent yet (`UsageStats`). Nil sends no
    /// answer, for a build that never asks.
    var answer: () -> UsageStatsConsent? = { nil }
    var pendingChanges: () -> [UsageStatsConsent.Change] = { [] }
    /// Called with the changes a count carried, once the Worker has them.
    var changesSent: ([UsageStatsConsent.Change]) -> Void = { _ in }

    private let defaults: UserDefaults
    private let base: URL?
    private let appVersion: String?
    private let now: () -> Date
    private let fetch: Fetch
    /// One request at a time. A call while one runs makes it look again once it's done, so a
    /// mouse found or an answer changed meanwhile isn't left for the next tick.
    private var sending = false
    private var again = false
    /// After a count the Worker didn't record, nothing more until the next tick: a refused
    /// count (a burst, the day's cap) asked again on every plug would only be refused again,
    /// and would use up the rate limit update checks share.
    private var quietUntil: Date?
    /// Well under the app's 15-minute tick (which has a minute's slack) and counted from when
    /// the refused request went out, so the tick after a refusal always tries again.
    static let retryAfter: TimeInterval = 10 * 60

    init(defaults: UserDefaults = .standard, base: URL? = WorkerEndpoint.base,
         appVersion: String? = AppInfo.version, now: @escaping () -> Date = Date.init,
         fetch: @escaping Fetch = { try await WorkerSession.shared.data(from: $0) }) {
        self.defaults = defaults
        self.base = base
        self.appVersion = appVersion
        self.now = now
        self.fetch = fetch
        // The switch that turned the mouse count off in 0.6.1 to 0.7.0. It's always on now.
        defaults.removeObject(forKey: "sendsMouseModels")
    }

    private static let dayKey = "mouseCountDay"
    private static let sentKey = "mouseCountSent"
    private static let answerKey = "countedStatsAnswer"

    /// Sends a count if there's anything the Worker hasn't heard today. Safe to call as often
    /// as anything likes: with nothing new it costs no request.
    func reportIfNeeded() async {
        if sending { again = true; return }
        sending = true
        defer { sending = false }
        repeat {
            again = false
            await sendOnce()
        } while again
    }

    private func sendOnce() async {
        if let quietUntil, now() < quietUntil { return }
        let mice = connectedMice()
        let answer = answer()
        let changes = pendingChanges()
        let day = Self.day(of: now())
        let sameDay = defaults.string(forKey: Self.dayKey) == day
        let sent = sameDay ? Set(defaults.stringArray(forKey: Self.sentKey) ?? []) : []
        let sentAnswer = sameDay ? defaults.string(forKey: Self.answerKey) : nil
        // A Mac with no Worker, or nothing to send at all, has nothing to count.
        let newMouse = mice.contains { !sent.contains(Self.key($0)) }
        let newAnswer = answer.map { $0.countValue != sentAnswer } ?? false
        guard newMouse || newAnswer || !changes.isEmpty,
              let url = WorkerEndpoint.releases(appVersion: appVersion, mice: mice, stats: answer,
                                                changes: changes, count: true, base: base) else { return }
        let started = now()
        do {
            let (_, response) = try await fetch(url)
            guard Self.counted(response) else {
                quietUntil = started.addingTimeInterval(Self.retryAfter)
                return
            }
            quietUntil = nil
            defaults.set(day, forKey: Self.dayKey)
            defaults.set(Array(sent.union(mice.map(Self.key))).sorted(), forKey: Self.sentKey)
            if let answer { defaults.set(answer.countValue, forKey: Self.answerKey) }
            if !changes.isEmpty { changesSent(changes) }
        } catch {
            // Background work: nothing to show anyone. The next tick tries again.
        }
    }

    /// Whether the Worker recorded the count. It says `x-counted: 1` when it did, even when the
    /// update list itself failed (a 502 while GitHub is down), and `x-counted: 0` when it
    /// didn't (a burst, the day's cap, a database error), so that's sent again on the next
    /// tick. A Worker from before the header says neither: then a 2xx is taken as counted, as
    /// it always was, rather than sending the whole count every tick.
    static func counted(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        switch http.value(forHTTPHeaderField: "x-counted") {
        case "1": return true
        case "0": return false
        default: return (200..<300).contains(http.statusCode)
        }
    }

    /// What the Worker counts a mouse by: its product ID and link.
    static func key(_ mouse: UsagePing.Mouse) -> String {
        String(format: "%04x", mouse.pid & 0xFFFF) + ".\(mouse.link)"
    }

    /// The UTC calendar day, as the Worker writes it.
    static func day(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

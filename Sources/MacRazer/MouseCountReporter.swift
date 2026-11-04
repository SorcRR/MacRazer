// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Tells the Worker which mouse models this Mac has connected today, so the reports page can
/// count the mice in use. Anonymous, like the update check it rides on: the same request, with
/// no ID for the Mac (see `WorkerEndpoint.releases`).
///
/// It used to go with the update check itself, which missed most mice. The check at launch
/// runs before the controller has found the mouse, and the next one is three hours away, so
/// a Mac used for an afternoon, or whose wireless mouse was asleep at those moments, was never
/// counted. Now a mouse goes out as soon as it's seen, and once a day (UTC, the Worker's day)
/// per model and link. A failed send is silent and tried again on the app's 15-minute tick.
@MainActor
final class MouseCountReporter {
    typealias Fetch = (URL) async throws -> (Data, URLResponse)

    /// The mice connected now. Set by the app delegate, which knows the controller.
    var connectedMice: () -> [UsagePing.Mouse] = { [] }

    private let defaults: UserDefaults
    private let base: URL?
    private let appVersion: String?
    private let now: () -> Date
    private let fetch: Fetch
    /// One request at a time. A call while one runs makes it look again once it's done, so a
    /// mouse found meanwhile isn't left for the next tick.
    private var sending = false
    private var again = false

    init(defaults: UserDefaults = .standard, base: URL? = WorkerEndpoint.base,
         appVersion: String? = AppInfo.version, now: @escaping () -> Date = Date.init,
         fetch: @escaping Fetch = { try await WorkerSession.shared.data(from: $0) }) {
        self.defaults = defaults
        self.base = base
        self.appVersion = appVersion
        self.now = now
        self.fetch = fetch
        // The switch that turned this off in 0.6.1 to 0.7.0. It's always on now.
        defaults.removeObject(forKey: "sendsMouseModels")
    }

    private static let dayKey = "mouseCountDay"
    private static let sentKey = "mouseCountSent"

    /// Sends the connected mice if any of them hasn't reached the Worker today. Safe to call
    /// as often as anything likes: with nothing new it costs no request.
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
        let mice = Array(connectedMice().prefix(WorkerEndpoint.maxMice))
        let day = Self.day(of: now())
        let sent = Self.sent(in: defaults, on: day)
        guard Self.isDue(mice, alreadySent: sent),
              let url = WorkerEndpoint.releases(appVersion: appVersion, mice: mice, base: base) else { return }
        do {
            let (_, response) = try await fetch(url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            defaults.set(day, forKey: Self.dayKey)
            defaults.set(Array(sent.union(mice.map(Self.key))).sorted(), forKey: Self.sentKey)
        } catch {
            // Background work: nothing to show anyone. The next tick tries again.
        }
    }

    /// Whether any connected mouse is missing from what went out today.
    static func isDue(_ mice: [UsagePing.Mouse], alreadySent: Set<String>) -> Bool {
        mice.contains { !alreadySent.contains(key($0)) }
    }

    /// What the Worker counts a mouse by: its product ID and link.
    static func key(_ mouse: UsagePing.Mouse) -> String {
        String(format: "%04x", mouse.pid & 0xFFFF) + ".\(mouse.link)"
    }

    /// The mice sent on `day`. Another day's list is no answer for today.
    static func sent(in defaults: UserDefaults, on day: String) -> Set<String> {
        guard defaults.string(forKey: dayKey) == day else { return [] }
        return Set(defaults.stringArray(forKey: sentKey) ?? [])
    }

    /// The UTC calendar day, as the Worker writes it.
    static func day(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

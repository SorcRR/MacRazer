// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The holiday count for the reports page, and the Worker's off switch for the decorations.
///
/// Anonymous, like the app's daily mouse count: no ID for the Mac, nothing that could tell one
/// person from another. It says which season, whether the decorations are on, off or not
/// answered yet, and any change since the last count (kept, turned off, back on), at most
/// once a UTC day unless there's a change to send. The reply says whether the decorations may
/// show, so a problem found after release can be switched off for everyone without one.
/// Failures are silent and tried again on the app's next tick.
@MainActor
public final class HolidayReporter {
    public typealias Fetch = (URL) async throws -> (Data, URLResponse)

    public static let shared = HolidayReporter(holiday: .shared)

    private let holiday: Holiday
    private var base: URL?
    private var appVersion: String?
    private var fetch: Fetch = { try await URLSession.shared.data(from: $0) }
    private var sending = false

    init(holiday: Holiday) { self.holiday = holiday }

    /// The app hands over where the Worker is and how it reaches it, at launch.
    public func configure(base: URL?, appVersion: String?, fetch: @escaping Fetch) {
        self.base = base
        self.appVersion = appVersion
        self.fetch = fetch
    }

    /// Sends a count when one is due. Safe to call as often as anything likes.
    public func reportIfNeeded() async {
        guard !sending, let year = holiday.seasonYear, let url = url(year: year) else { return }
        let changes = holiday.pendingChanges
        let day = Self.utcDay(holiday.now())
        let sentToday = holiday.stored(String.self, "countDay") == day
        guard !sentToday || !changes.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            let (data, response) = try await fetch(url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            holiday.setStored(day, "countDay")
            holiday.changesSent(changes)
            if let reply = try? JSONDecoder().decode(Reply.self, from: data) {
                holiday.setRemoteAllowed(reply.enabled)
            }
        } catch {
            // Background work: nothing to show anyone. The next tick tries again.
        }
    }

    struct Reply: Decodable { let enabled: Bool }

    /// The request, exactly as the Worker takes it (`src/holiday.ts` in macrazer-worker).
    func url(year: Int) -> URL? {
        guard let base, var parts = URLComponents(url: base.appendingPathComponent("v1/holiday"), resolvingAgainstBaseURL: false) else { return nil }
        var items = [URLQueryItem(name: "season", value: String(year)),
                     URLQueryItem(name: "state", value: holiday.stateForCount)]
        let changes = holiday.pendingChanges
        if !changes.isEmpty { items.append(URLQueryItem(name: "changes", value: changes.map(\.rawValue).joined(separator: ","))) }
        if let appVersion { items.append(URLQueryItem(name: "app", value: appVersion)) }
        parts.queryItems = items
        return parts.url
    }

    static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }
}

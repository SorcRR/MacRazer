// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The Worker's copy of the support list, `GET /v1/support-list`: each row's `unverified` as it
/// stands on master. A report often confirms a feature days after a release, and without this
/// everyone with that mouse would be asked for the test until the next one ships.
///
/// It can only take features off a row's list, never add one, and it says nothing about how
/// to talk to the mouse. So the worst a wrong list can do is skip some prompts. It is used
/// only by the version it was made for: an older build's table is older than this one's, and
/// a newer release may have confirmed a feature with code this build doesn't have.
struct SupportList: Equatable {
    /// The Worker's `SCHEMA` (src/support-list.ts). Bump both together.
    static let schema = 1
    /// Far more than the list needs, so junk costs little.
    static let maxBytes = 64 * 1024
    static let maxRows = 1000

    /// The app version on master when the Worker's table was made.
    let version: String
    let commit: String
    /// Per pid, what the list still has as unverified, for rows that passed the checks.
    let remaining: [Int: Set<RazerFeature>]

    private struct Wire: Decodable {
        let schema: Int
        let version: String
        let commit: String
        let mice: [Row]
        struct Row: Decodable {
            let pid: Int
            let link: String
            let unverified: [String]
        }
    }

    /// The list, or nil when it's not one this build reads. A row is left out, so the built-in
    /// one stands, when the app has no row for its pid, when its link isn't that row's, or when
    /// it names a feature this build doesn't know: dropping just the name would count that
    /// feature as confirmed.
    static func decode(_ data: Data, rows: [RazerDeviceInfo] = RazerDevices.known) -> SupportList? {
        guard data.count <= maxBytes,
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              wire.schema == schema, wire.mice.count <= maxRows else { return nil }
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var remaining: [Int: Set<RazerFeature>] = [:]
        for row in wire.mice {
            guard let local = byPID[row.pid], link(local.connection) == row.link else { continue }
            let features = row.unverified.compactMap(RazerFeature.init(rawValue:))
            guard features.count == row.unverified.count else { continue }
            remaining[row.pid] = Set(features)
        }
        return SupportList(version: wire.version, commit: wire.commit, remaining: remaining)
    }

    /// The Worker's names for a link, as `npm run mice` writes them.
    static func link(_ connection: RazerConnection) -> String {
        switch connection {
        case .wired: return "wired"
        case .wirelessDongle: return "dongle"
        case .bluetooth: return "bluetooth"
        }
    }

    /// Whether this build should use it: made for this version. Master keeps the released
    /// version until the next release, so that's every list made between the two.
    func applies(to appVersion: String) -> Bool {
        !VersionCompare.isNewer(appVersion, than: version) && !VersionCompare.isNewer(version, than: appVersion)
    }
}

/// Keeps `RazerDevices` up to date with the Worker's support list. The last good list is kept
/// and applied at launch, before any network call, so prompts are right offline. It is asked
/// for no more often than the update check, and a failure of any kind just keeps what's there.
///
/// Nothing about the Mac or its mice is sent: a bare GET through `WorkerSession`, with the
/// same user agent as the other requests. So it isn't tied to the usage stats' consent.
@MainActor
final class SupportListUpdater {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let interval = UpdateChecker.checkInterval
    static let listKey = "supportList.data"
    static let fetchedKey = "supportList.fetchedAt"

    private let defaults: UserDefaults
    private let endpoint: URL?
    private let version: String
    private let transport: Transport
    private let apply: ([Int: Set<RazerFeature>]) -> Void
    private var running: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         endpoint: URL? = WorkerEndpoint.supportList,
         version: String = AppInfo.comparableVersion,
         transport: @escaping Transport = { try await WorkerSession.shared.data(for: $0) },
         apply: @escaping ([Int: Set<RazerFeature>]) -> Void = RazerDevices.applySupportList) {
        self.defaults = defaults
        self.endpoint = endpoint
        self.version = version
        self.transport = transport
        self.apply = apply
    }

    /// Applies the kept list, if it still suits this build. One from another version, such as
    /// the one before an update, is dropped along with its date, so this build asks straight away.
    func applyCached() {
        guard let data = defaults.data(forKey: Self.listKey) else { return }
        guard let list = SupportList.decode(data), list.applies(to: version) else {
            defaults.removeObject(forKey: Self.listKey)
            defaults.removeObject(forKey: Self.fetchedKey)
            return
        }
        apply(list.remaining)
    }

    static func isDue(lastFetched: Date?, now: Date) -> Bool {
        guard let lastFetched else { return true }
        return now.timeIntervalSince(lastFetched) >= interval
    }

    /// Asks the Worker when the last good answer is old enough. Safe to call from every
    /// trigger the update check has; one request runs at a time.
    func refreshIfDue(now: Date = Date()) async {
        guard endpoint != nil,
              Self.isDue(lastFetched: defaults.object(forKey: Self.fetchedKey) as? Date, now: now) else { return }
        if let running { return await running.value }
        let task = Task { await fetch(now: now) }
        running = task
        await task.value
        running = nil
    }

    private func fetch(now: Date) async {
        guard let endpoint else { return }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("MacRazer/\(AppInfo.displayVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await transport(request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let list = SupportList.decode(data) else { return }
        // A good answer counts against the interval even when it's for another version: asking
        // again sooner wouldn't change it until the Worker is regenerated.
        defaults.set(now, forKey: Self.fetchedKey)
        guard list.applies(to: version) else {
            defaults.removeObject(forKey: Self.listKey)
            apply([:])
            return
        }
        defaults.set(data, forKey: Self.listKey)
        apply(list.remaining)
    }
}

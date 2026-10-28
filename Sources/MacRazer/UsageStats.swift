// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CryptoKit
import Foundation
import IOKit

/// What the person said when asked about usage stats. Nothing is sent unless it's `granted`.
enum UsageStatsConsent: String {
    case undecided, granted, declined
}

/// One ping, exactly as the Worker takes it (`src/stats.ts` in SorcRR/macrazer-worker). Settings shows this same
/// value as JSON, so what the person reads is what goes.
struct UsagePing: Codable, Equatable {
    enum Event: String, Codable {
        /// The first ping since the app's preferences were empty: a new install, usually.
        case first
        /// The app's version changed since the last ping.
        case update
        /// A mouse this Mac hadn't reported yet.
        case mouse
    }

    struct Mouse: Codable, Equatable {
        var pid: Int
        var name: String
        /// "wired", "dongle", "bluetooth" or "unknown". A product ID means nothing without
        /// it: Bluetooth IDs come from a different vendor number than USB ones.
        var link: String
        /// Whether MacRazer has a verified profile for it. The unsupported ones are the point:
        /// they say which mouse to add next.
        var supported: Bool

        /// How the Mac remembers having reported it.
        var key: String { "\(pid)/\(link)" }
    }

    var v = 1
    var id: String
    var event: Event
    var app: String
    var os: String
    var arch: String
    var mice: [Mouse]

    func json(pretty: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// When a ping is due. Pure, so the rules are tested apart from the network and the clock.
enum UsageStatsPolicy {
    static func event(consent: UsageStatsConsent, version: String?, lastReportedVersion: String?,
                      reportedMice: Set<String>, connected: [UsagePing.Mouse]) -> UsagePing.Event? {
        // A `swift run` build has no version, and its pings would only be noise.
        guard consent == .granted, let version else { return nil }
        guard let lastReportedVersion else { return .first }
        if lastReportedVersion != version { return .update }
        if connected.contains(where: { !reportedMice.contains($0.key) }) { return .mouse }
        return nil
    }

    /// The mouse as a ping names it. The registry's name when MacRazer knows the model, so
    /// one model isn't counted under several USB product strings; the mouse's own otherwise.
    static func mouse(pid: Int, productName: String?, isBluetooth: Bool, supported: Bool) -> UsagePing.Mouse {
        let link: String
        if isBluetooth {
            link = "bluetooth"
        } else {
            switch RazerDevices.connection(pid: pid) {
            case .wired: link = "wired"
            case .wirelessDongle: link = "dongle"
            case .bluetooth: link = "bluetooth"
            case nil: link = "unknown"
            }
        }
        let name = RazerDevices.info(pid: pid)?.name ?? productName ?? "Unknown mouse"
        return UsagePing.Mouse(pid: pid, name: fitted(name, utf16: 64), link: link, supported: supported)
    }

    /// Whole characters, up to `utf16` UTF-16 units: the Worker counts in those, and a cut of
    /// its own could split an emoji in half.
    static func fitted(_ text: String, utf16 limit: Int) -> String {
        var out = ""
        var used = 0
        for character in text {
            used += character.utf16.count
            if used > limit { break }
            out.append(character)
        }
        return out
    }
}

/// The ID a Mac is counted under. A keyed SHA-256 of the hardware UUID, so the same Mac gets
/// the same ID after a reinstall, and the UUID itself never leaves it. The key is public (this
/// is open source), so the point of it isn't secrecy: it makes this ID different from the one
/// any other app would get by hashing the same UUID, so the two can't be matched up.
enum UsageMachineID {
    private static let key = SymmetricKey(data: Data("MacRazer usage stats v1".utf8))

    static func id(fromHardwareUUID uuid: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(uuid.uppercased().utf8), using: key)
        return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// `IOPlatformUUID`: the same value System Information shows as Hardware UUID.
    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }

    /// The Mac's chip, not this process's: under Rosetta the app runs as x86_64 on Apple
    /// Silicon, and counting that as Intel would be wrong.
    static var arch: String {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let found = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0
        return found && value == 1 ? "arm64" : "x86_64"
    }
}

/// Opt-in usage stats: asks once, then pings the Worker on install, on update, and when a new
/// mouse shows up. Settings › Privacy turns it off, shows exactly what's sent, and deletes it.
@MainActor
final class UsageStats: ObservableObject {
    static let consentKey = "usageStats.consent"
    static let idKey = "usageStats.id"
    static let lastReportedVersionKey = "usageStats.lastReportedVersion"
    static let reportedMiceKey = "usageStats.reportedMice"
    static let lastSentAtKey = "usageStats.lastSentAt"
    /// An ID whose Delete My Data hasn't reached the server yet. Retried until it does.
    static let pendingDeletionKey = "usageStats.pendingDeletion"

    static let shared = UsageStats()

    enum DeletionState: Equatable {
        case idle, deleting, deleted
        /// Couldn't reach the server. The ID is kept and the delete is tried again.
        case willRetry
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    @Published private(set) var consent: UsageStatsConsent
    @Published private(set) var lastSentAt: Date?
    @Published private(set) var lastSentVersion: String?
    @Published private(set) var deletion: DeletionState = .idle
    /// The mice connected right now, as the controller last reported them.
    @Published private(set) var connectedMice: [UsagePing.Mouse] = []

    private let defaults: UserDefaults
    private let transport: Transport
    /// Nil in a build without the Worker: then nothing is asked, shown or sent.
    private let endpoint: URL?
    private let version: String?
    private let hardwareUUID: () -> String?
    /// Whether a yes or a new mouse sends straight away. Off in tests, which call
    /// `sendIfDue` themselves so the order of requests is theirs to check.
    private let sendsOnChange: Bool
    private var busy = false
    private var again = false

    init(defaults: UserDefaults = .standard,
         endpoint: URL? = WorkerEndpoint.usageStats,
         version: String? = AppInfo.version,
         hardwareUUID: @escaping () -> String? = UsageMachineID.hardwareUUID,
         sendsOnChange: Bool = true,
         transport: @escaping Transport = { try await WorkerSession.shared.data(for: $0) }) {
        self.sendsOnChange = sendsOnChange
        self.defaults = defaults
        self.endpoint = endpoint
        self.version = version
        self.hardwareUUID = hardwareUUID
        self.transport = transport
        consent = defaults.string(forKey: Self.consentKey).flatMap(UsageStatsConsent.init) ?? .undecided
        lastSentAt = defaults.object(forKey: Self.lastSentAtKey) as? Date
        lastSentVersion = defaults.string(forKey: Self.lastReportedVersionKey)
        if defaults.string(forKey: Self.pendingDeletionKey) != nil { deletion = .willRetry }
    }

    /// Whether this build has somewhere to send stats. When it doesn't, the app never asks,
    /// Settings has no Privacy section, and the Updated window has no card.
    var isAvailable: Bool { endpoint != nil }

    /// Worked out once and kept: if macOS ever reported a different UUID (some have seen it
    /// change across a major upgrade) the Mac would otherwise turn into a new one. Recomputed
    /// only when the preferences are gone, which gives the same answer on the same Mac.
    var machineID: String {
        if let stored = defaults.string(forKey: Self.idKey) { return stored }
        // No UUID at all would be a very odd Mac. A random ID still counts it, just not
        // across a reinstall.
        let id = hardwareUUID().map(UsageMachineID.id(fromHardwareUUID:))
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: Self.idKey)
        return id
    }

    private var reportedMice: Set<String> {
        Set(defaults.stringArray(forKey: Self.reportedMiceKey) ?? [])
    }

    /// What the next ping would be, for Settings to show. The event is whatever is due, or
    /// "update" when nothing is, since that's what the next one will most likely be.
    var preview: UsagePing {
        let event = UsageStatsPolicy.event(
            consent: .granted, version: version ?? "dev", lastReportedVersion: defaults.string(forKey: Self.lastReportedVersionKey),
            reportedMice: reportedMice, connected: connectedMice)
        return ping(event ?? .update)
    }

    private func ping(_ event: UsagePing.Event) -> UsagePing {
        UsagePing(id: machineID, event: event, app: version ?? "dev",
                  os: DeviceReport.currentMacOSVersion, arch: UsageMachineID.arch, mice: connectedMice)
    }

    // MARK: Asking

    func setConsent(_ granted: Bool) {
        consent = granted ? .granted : .declined
        defaults.set(consent.rawValue, forKey: Self.consentKey)
        if granted {
            if deletion == .deleted { deletion = .idle }
            if sendsOnChange { Task { await sendIfDue() } }
        }
    }

    /// Closing a window that asked, without answering, is a no. It isn't asked again.
    func dismissUnanswered() {
        if consent == .undecided { setConsent(false) }
    }

    // MARK: Sending

    /// The controller's connected mouse, or none. A new one may make a ping due.
    func setConnectedMice(_ mice: [UsagePing.Mouse]) {
        guard mice != connectedMice else { return }
        connectedMice = mice
        if sendsOnChange { Task { await sendIfDue() } }
    }

    /// Sends whatever is due: an unfinished deletion first, then a ping. Called at launch, on
    /// a new mouse, and on saying yes. A call while one is running makes it go round once more,
    /// so nothing that changed meanwhile is missed.
    func sendIfDue() async {
        guard endpoint != nil else { return }
        if busy { again = true; return }
        busy = true
        defer { busy = false }
        repeat {
            again = false
            // A ping before an owed delete reached the server would be deleted along with it.
            if defaults.string(forKey: Self.pendingDeletionKey) != nil {
                // A failure ends the pass, unless something asked for another meanwhile.
                guard await finishDeletion() else { continue }
            }
            guard let event = UsageStatsPolicy.event(
                consent: consent, version: version,
                lastReportedVersion: defaults.string(forKey: Self.lastReportedVersionKey),
                reportedMice: reportedMice, connected: connectedMice) else { continue }
            let sent = ping(event)
            // On failure, go round again only if something changed during the request: a
            // Delete My Data made then must not wait for the next launch.
            guard await post(sent) else { continue }
            // Recorded only on success, so a failed ping is simply due again next time.
            // And only if nothing changed meanwhile: a delete during the request wins.
            guard consent == .granted else { continue }
            defaults.set(sent.app, forKey: Self.lastReportedVersionKey)
            defaults.set(Array(reportedMice.union(sent.mice.map(\.key))).sorted(), forKey: Self.reportedMiceKey)
            let now = Date()
            defaults.set(now, forKey: Self.lastSentAtKey)
            lastSentAt = now
            lastSentVersion = sent.app
        } while again
    }

    private func post(_ ping: UsagePing) async -> Bool {
        guard let endpoint else { return false }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MacRazer/\(AppInfo.displayVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(ping.json(pretty: false).utf8)
        return await succeeds(request)
    }

    // MARK: Deleting

    /// Delete My Data: sharing goes off at once, and the server is asked to drop this Mac's ID.
    /// If it can't be reached, the request is kept and tried again until it is.
    func deleteMyData() async {
        // A build without the Worker never sent anything, and has nowhere to ask.
        guard endpoint != nil else { return }
        defaults.set(machineID, forKey: Self.pendingDeletionKey)
        // Shown straight away, even when a ping in flight makes the delete wait for it.
        deletion = .deleting
        consent = .declined
        defaults.set(consent.rawValue, forKey: Self.consentKey)
        // Forget what was reported, so opting in again starts over as a new Mac, the way the
        // server will see it.
        for key in [Self.lastReportedVersionKey, Self.reportedMiceKey, Self.lastSentAtKey] {
            defaults.removeObject(forKey: key)
        }
        lastSentAt = nil
        lastSentVersion = nil
        await sendIfDue()
    }

    /// True once the server has it, or there was nothing to delete.
    private func finishDeletion() async -> Bool {
        guard let id = defaults.string(forKey: Self.pendingDeletionKey) else { return true }
        guard let endpoint else { return false }
        deletion = .deleting
        var request = URLRequest(url: endpoint.appendingPathComponent(id),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "DELETE"
        request.setValue("MacRazer/\(AppInfo.displayVersion)", forHTTPHeaderField: "User-Agent")
        guard await succeeds(request) else {
            deletion = .willRetry
            return false
        }
        defaults.removeObject(forKey: Self.pendingDeletionKey)
        deletion = .deleted
        return true
    }

    private func succeeds(_ request: URLRequest) async -> Bool {
        guard let (_, response) = try? await transport(request) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// For the `render-…` previews: this Mac's look with made-up state, in a scratch domain so
    /// drawing a preview never touches the real preferences or the network.
    static func preview(consent: UsageStatsConsent = .granted) -> UsageStats {
        let name = "MacRazer.preview.usageStats"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let stats = UsageStats(defaults: defaults, endpoint: URL(string: "https://reports.example/v1/stats"), version: "0.6.0",
                               hardwareUUID: { "5C0FFEE0-0000-4000-8000-000000000000" },
                               sendsOnChange: false, transport: { _ in throw URLError(.notConnectedToInternet) })
        stats.consent = consent
        stats.connectedMice = [UsageStatsPolicy.mouse(pid: 0x00B0, productName: nil, isBluetooth: false, supported: true)]
        if consent == .granted {
            stats.lastSentAt = Date()
            stats.lastSentVersion = "0.6.0"
        }
        return stats
    }
}

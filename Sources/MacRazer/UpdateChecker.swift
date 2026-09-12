// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Foundation

/// Polls GitHub Releases once a day for a newer MacRazer version, and installs it.
///
/// No Sparkle/appcast — the app is unsigned-by-Apple and distributed as a plain DMG. When
/// MacRazer is installed somewhere it can write to, "update" means the whole manual routine
/// done for you: fetch the DMG, verify it, swap the bundle, relaunch (`UpdateInstaller`).
/// Everywhere else — running from the image itself, a translocated copy, a folder the user
/// can't write — it falls back to what this used to do: download the DMG and open it, so the
/// user drags it across as before.
@MainActor
final class UpdateChecker: ObservableObject {
    /// What the update card is doing right now. Drives a real progress bar: a multi-megabyte
    /// download behind a bare spinner is indistinguishable from a hang.
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        /// Mounting, checking and swapping the bundle — seconds, and not meaningfully
        /// divisible into steps a user would care to watch.
        case installing
        case restarting
        /// Installed, but the new instance wouldn't start — the user has to quit and reopen.
        /// A terminal state, and deliberately not an error: offering the DMG again here would
        /// invite reinstalling over an update that already succeeded.
        case needsRestart
    }

    @Published private(set) var latestVersion: String?
    @Published private(set) var phase: Phase = .idle
    @Published var downloadError: String?
    /// A check is in flight. Only the manual "Check Now" needs this — the daily background
    /// check has nothing to say while it runs.
    @Published private(set) var isChecking = false

    /// Notes for `latestVersion`, parsed for the popover. Nil when the release had no body or
    /// nothing has been found — the "What's new" row hides itself rather than opening onto an
    /// empty page.
    @Published private(set) var latestNotes: [VersionedNotes] = []

    /// Notes for everything gained by the update just installed: the releases after the
    /// version that was running before, up to and including this one.
    ///
    /// A span rather than one release, because skipping versions is normal. Going from 0.3.0
    /// to 0.4.1 used to show 0.4.1's notes alone, which opened by describing a bug in a
    /// release the reader had never run and said nothing about the features they had just
    /// gained. Kept separate from `latestNotes` because both can exist at once: you can be
    /// reading about what you just installed when the next release appears.
    @Published private(set) var installedNotes: [VersionedNotes] = []

    /// Set on the first launch after the version changes, until dismissed. The one way someone
    /// with automatic installs on finds out a release happened at all.
    @Published private(set) var justUpdatedTo: String?

    /// The error from the last failed install, kept raw (not just its message) so
    /// `AutoInstallPolicy` can tell a dropped connection from a payload that will never work.
    private(set) var lastInstallError: Error?

    /// When the last successful check ran, shown by the settings window so "no update" reads
    /// as a fresh answer rather than a shrug.
    ///
    /// A stored published property, seeded from `UserDefaults` and written alongside it. It
    /// was a computed read of the default, which published nothing, so the line refreshed only
    /// because some *other* property happened to change around each check — first `isChecking`,
    /// then a write-only counter added to make that deliberate. Storing it removes the
    /// question: the value the view reads is the value that publishes.
    @Published private(set) var lastCheckedAt: Date?

    /// Install updates without asking. **Off by default**: installing and relaunching behind
    /// someone's back is a much bigger thing to do to them than putting a dot on the menu bar,
    /// and this app isn't Apple-notarised — opting in should be deliberate. The caller decides
    /// *when* an automatic install is acceptable (`AppDelegate` won't start one with the
    /// popover open); this flag only says whether it may.
    @Published var autoInstallEnabled: Bool = false {
        didSet { defaults.set(autoInstallEnabled, forKey: Self.autoInstallKey) }
    }

    /// Where the state above is kept between launches.
    ///
    /// Injectable, and not because anything else stores it elsewhere. Every *decision* in this
    /// class is a pure function with tests, and both bugs this feature shipped were in the
    /// wiring between those functions and these keys: an announcement held only in memory, and
    /// then a cache written by a version that had no such key. Neither could be written as a
    /// test while the store was `UserDefaults.standard`.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastCheckedAt = defaults.object(forKey: Self.lastCheckKey) as? Date
        // Assigned after `defaults` exists, and directly to the backing store, so the `didSet`
        // above does not write the value straight back during initialisation.
        _autoInstallEnabled = Published(initialValue: defaults.bool(forKey: Self.autoInstallKey))
    }

    private let releaseAPIURL = ProjectLinks.releasesAPI
    private let dmgURL = ProjectLinks.latestDMG
    private let checkInterval: TimeInterval = 24 * 60 * 60

    private static let dismissedKey = "dismissedUpdateVersion"
    private static let lastCheckKey = "lastUpdateCheckDate"
    private static let lastFoundKey = "lastFoundUpdateVersion"
    private static let autoInstallKey = "autoInstallUpdates"
    private static let lastFoundNotesKey = "lastFoundUpdateNotes"
    private static let lastRunVersionKey = "lastRunVersion"
    private static let dismissedAnnouncementKey = "dismissedUpdateAnnouncement"
    private static let pendingAnnouncementKey = "pendingUpdateAnnouncement"
    private static let notesCheckedForKey = "notesCheckedForVersion"
    /// The version running before this one, kept while an announcement is pending so the span
    /// it describes still has a start. `lastRunVersion` is overwritten at launch and cannot
    /// answer this afterwards.
    private static let updatedFromKey = "updatedFromVersion"
    /// Every release the last check saw, as JSON. Was a single body, which could only ever
    /// describe one release.
    private static let cachedReleasesKey = "cachedReleases"

    private struct GitHubRelease: Decodable {
        let tag_name: String
        /// The release notes. Optional because a release can be published without a body, and
        /// a missing one must not fail the version check that is the point of this request.
        let body: String?
        let prerelease: Bool?
        let draft: Bool?

        /// Tags are written `v0.4.1`; everything else here compares bare dotted integers.
        var remote: RemoteRelease {
            RemoteRelease(version: tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name,
                          body: body ?? "",
                          isPrerelease: prerelease ?? false,
                          isDraft: draft ?? false)
        }
    }

    var currentVersion: String { AppInfo.comparableVersion }

    var isBusy: Bool { phase != .idle }

    /// Whether the one-click "Update & Restart" path is available, or the card should offer
    /// the manual DMG instead.
    var canInstallInPlace: Bool { UpdateInstaller.canInstallInPlace }

    /// Checks at most once per `checkInterval`, regardless of how often this is called — safe to
    /// call on every launch and from a repeating timer.
    func checkForUpdatesIfDue() async {
        if Self.isCheckDue(lastChecked: lastCheckedAt,
                           now: Date(),
                           interval: checkInterval,
                           notesMissingForNewVersion: notesWorthFetching) {
            await checkForUpdatesNow()
            return
        }
        // Within the throttle window, surface what the last successful check already found.
        // Otherwise a relaunch forgets a known update for up to a day.
        restoreLastFound()
    }

    /// A fresh version with no notes, and no check made for it yet.
    ///
    /// The last clause is what stops this repeating. Without it, a release published with no
    /// body leaves `installedNotes` nil however many checks run, so every launch would skip
    /// the throttle and go to the network again for as long as the announcement stood.
    private var notesWorthFetching: Bool {
        justUpdatedTo != nil
            && installedNotes.isEmpty
            && defaults.string(forKey: Self.notesCheckedForKey) != currentVersion
    }

    #if DEBUG
    /// The condition above, for the test that states when it must stop firing.
    var notesWorthFetchingForTesting: Bool { notesWorthFetching }
    #endif

    /// Whether to go to the network now.
    ///
    /// The throttle exists so the app asks once a day however often it launches. It has one
    /// exception, and 0.4.0 is what found it: the version just changed and there are no notes
    /// for what is now running, which means the cache was written by the version that is no
    /// longer here. Every 0.3.0 install hit this, because 0.3.0 had no notes cache at all, so
    /// the release that introduced "What's new" showed the card with nothing to open. Waiting
    /// out a day for text that is already published is the wrong trade.
    ///
    /// Self-limiting: the check it forces fills the cache, so the next call takes the
    /// ordinary path.
    static func isCheckDue(lastChecked: Date?,
                           now: Date,
                           interval: TimeInterval,
                           notesMissingForNewVersion: Bool) -> Bool {
        if notesMissingForNewVersion { return true }
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }

    /// Bypasses the throttle — used by `checkForUpdatesIfDue()` once due, and by the menu's
    /// "Check for Updates…".
    ///
    /// `userRequested` also drops a previous "dismiss": someone who goes looking for an update
    /// wants the answer, not the silence they asked for last week. Without it the menu item
    /// would be a no-op for exactly the people who dismissed the card and later changed their
    /// mind — the only ones who'd think to use it.
    func checkForUpdatesNow(userRequested: Bool = false) async {
        // Never while installing. A check that resolves to "nothing newer" clears
        // `latestVersion`, and the popover's whole update card is mounted on that — so a
        // background check landing mid-install would erase the progress bar out from under a
        // swap-and-relaunch already in flight. There is also nothing to learn: we are already
        // installing the newest thing we know about.
        guard !isBusy else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: releaseAPIURL)
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data).map(\.remote)
            // GitHub's `releases/latest` applied "no drafts, no prereleases" on its side. The
            // list does not, so the rule lives in `ReleaseSpan` now, with tests.
            let published = ReleaseSpan.publishable(releases)
            guard let newest = published.first else { return }
            let remote = newest.version
            // Only *now* drop a previous dismissal — after the check actually succeeded.
            // Clearing it up front spent the user's decision even when the request then
            // failed, and `restoreLastFound()` would resurrect the very version they had
            // dismissed, having learned nothing.
            if userRequested { defaults.removeObject(forKey: Self.dismissedKey) }
            // Only a *successful* check counts against the daily throttle: a failed one
            // (offline right after wake is common) should retry on the next opportunity,
            // not silence update notices for a day.
            let checkedAt = Date()
            defaults.set(checkedAt, forKey: Self.lastCheckKey)
            defaults.set(remote, forKey: Self.lastFoundKey)
            Self.cache(published, in: defaults)
            lastCheckedAt = checkedAt
            let dismissed = defaults.string(forKey: Self.dismissedKey)
            if Self.isNewer(remote, than: currentVersion), remote != dismissed {
                latestVersion = remote
                latestNotes = Self.parsed(ReleaseSpan.newer(than: currentVersion, in: published))
            } else {
                latestVersion = nil
                latestNotes = []
            }
            // The same response answers "what am I running?" — someone who installed by hand
            // gets their notes from the first check after, without waiting for a next release.
            installedNotes = Self.installedNotes(current: currentVersion, defaults: defaults)
            // Asked and answered, whatever the answer was. A release with no body has no notes
            // to find, and retrying that on every launch would be a request that cannot help.
            defaults.set(currentVersion, forKey: Self.notesCheckedForKey)
        } catch {
            // Silent: a failed background check shouldn't surface as an error — only an
            // explicit download attempt should show one. But do surface what the last
            // *successful* check found, or an offline relaunch hides a known update.
            restoreLastFound()
        }
    }

    /// Re-applies the newest remote version a past check found (newer-than-current and
    /// not-dismissed are re-evaluated, so updating or dismissing in the meantime clears it).
    private func restoreLastFound() {
        guard latestVersion == nil,
              let found = defaults.string(forKey: Self.lastFoundKey) else { return }
        let dismissed = defaults.string(forKey: Self.dismissedKey)
        if Self.isNewer(found, than: currentVersion), found != dismissed {
            latestVersion = found
            latestNotes = Self.parsed(ReleaseSpan.newer(than: currentVersion,
                                                        in: Self.cachedReleases(defaults)))
        }
    }

    func dismiss(_ version: String) {
        defaults.set(version, forKey: Self.dismissedKey)
        latestVersion = nil
        latestNotes = []
    }

    /// Works out whether this launch is the first on a new version, and loads the notes for
    /// whatever is running. Call once, at startup.
    ///
    /// Recording the version is unconditional and happens here rather than at quit: an app
    /// that is killed, crashes, or is replaced under itself never gets a clean shutdown, and
    /// the one thing worse than a missed announcement is the same one every launch.
    func loadInstalledVersionState() {
        let current = currentVersion
        let lastRun = defaults.string(forKey: Self.lastRunVersionKey)
        let pending = UpdateAnnouncement.pending(
            lastRun: lastRun,
            current: current,
            dismissed: defaults.string(forKey: Self.dismissedAnnouncementKey),
            storedPending: defaults.string(forKey: Self.pendingAnnouncementKey),
            hasRunBefore: Self.hasRunBefore(defaults))
        justUpdatedTo = pending
        // Written down rather than only held: the card waits for the popover to be opened,
        // which can be days, and a reboot in between must not swallow it.
        if let pending {
            defaults.set(pending, forKey: Self.pendingAnnouncementKey)
            // Only when the announcement is created, never on a later launch: `lastRun` is
            // about to be overwritten with `current`, and re-recording it then would collapse
            // the span to nothing before it had been read.
            if lastRun != nil, defaults.string(forKey: Self.updatedFromKey) == nil {
                defaults.set(lastRun, forKey: Self.updatedFromKey)
            }
        } else {
            defaults.removeObject(forKey: Self.pendingAnnouncementKey)
            defaults.removeObject(forKey: Self.updatedFromKey)
        }
        defaults.set(current, forKey: Self.lastRunVersionKey)
        installedNotes = Self.installedNotes(current: current, defaults: defaults)
    }

    /// Evidence that some version of MacRazer has run on this machine before.
    ///
    /// Asked only when no version was recorded, which happens exactly once per install: the
    /// upgrade from a build older than this bookkeeping. Both keys predate it — the update
    /// check has written its date since 0.2.0, and the login-item default has recorded itself
    /// since 0.3.0 — so between them they cover anyone who has either been online once or run
    /// from an installed bundle once. Someone who has done neither is announced nothing, which
    /// is the same thing a genuinely new install gets, and the About window still has the
    /// notes.
    private static func hasRunBefore(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: lastCheckKey) != nil
            || defaults.object(forKey: LaunchAtLogin.appliedDefaultKey) != nil
    }

    func dismissAnnouncement() {
        if let version = justUpdatedTo {
            defaults.set(version, forKey: Self.dismissedAnnouncementKey)
        }
        defaults.removeObject(forKey: Self.pendingAnnouncementKey)
        defaults.removeObject(forKey: Self.updatedFromKey)
        justUpdatedTo = nil
    }

    /// The same notes, for a caller with no `UpdateChecker` to hand — the About window, which
    /// observes nothing.
    static func notesForRunningVersion(defaults: UserDefaults = .standard) -> [VersionedNotes] {
        installedNotes(current: AppInfo.comparableVersion, defaults: defaults)
    }

    /// Everything gained by the update just installed, from the cache the last check filled.
    private static func installedNotes(current: String, defaults: UserDefaults) -> [VersionedNotes] {
        parsed(ReleaseSpan.between(from: defaults.string(forKey: updatedFromKey),
                                   upToAndIncluding: current,
                                   in: cachedReleases(defaults)))
    }

    /// Bodies are a couple of kilobytes of prose each and a SwiftUI body can run many times a
    /// second, so they are parsed here rather than in the view. A release whose notes come out
    /// empty is dropped: a version heading with nothing under it says less than nothing.
    private static func parsed(_ releases: [RemoteRelease]) -> [VersionedNotes] {
        releases.compactMap { release in
            let notes = ReleaseNotes.parse(release.body)
            return notes.isEmpty ? nil : VersionedNotes(version: release.version, notes: notes)
        }
    }

    /// How many releases' notes to keep on disk.
    ///
    /// This lands in the preferences plist, which is read at every launch, so it cannot be
    /// allowed to grow with the project's age. Six is comfortably more than any real span:
    /// someone six releases behind is not going to read all of them, and the notes they most
    /// need are the recent ones either way.
    private static let maxCachedReleases = 6

    private static func cache(_ releases: [RemoteRelease], in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(Array(releases.prefix(maxCachedReleases))) else { return }
        defaults.set(data, forKey: cachedReleasesKey)
    }

    /// What the last check saw.
    ///
    /// Falls back to the single body older versions stored under `lastFoundUpdateNotes`, so
    /// the first launch after upgrading still has something to show rather than waiting for a
    /// check to refill the new cache.
    private static func cachedReleases(_ defaults: UserDefaults) -> [RemoteRelease] {
        if let data = defaults.data(forKey: cachedReleasesKey),
           let releases = try? JSONDecoder().decode([RemoteRelease].self, from: data) {
            return releases
        }
        guard let version = defaults.string(forKey: lastFoundKey),
              let body = defaults.string(forKey: lastFoundNotesKey), !body.isEmpty else { return [] }
        return [RemoteRelease(version: version, body: body)]
    }


    // MARK: - Installing

    /// Download the new DMG, replace this app with the copy inside it, and relaunch into it.
    /// Falls back to `downloadAndOpenDMG()` wherever an in-place swap isn't possible, so the
    /// button always does *something* useful.
    func downloadAndInstall() async {
        guard !isBusy else { return }
        guard let target = UpdateInstaller.installTarget, UpdateInstaller.canInstallInPlace else {
            await downloadAndOpenDMG()
            return
        }
        downloadError = nil
        lastInstallError = nil
        phase = .downloading(0)
        let bundleID = Bundle.main.bundleIdentifier
        let current = currentVersion
        do {
            let dmg = try await downloadDMG()
            defer { try? FileManager.default.removeItem(at: dmg.deletingLastPathComponent()) }
            phase = .installing
            // Off the main actor: mounting, verifying and copying a bundle would freeze the
            // popover (and the menu bar) for the seconds it takes.
            _ = try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.installInPlace(
                    dmg: dmg, into: target, expectedBundleID: bundleID, currentVersion: current)
            }.value
            phase = .restarting
            relaunch(at: target)
        } catch {
            phase = .idle
            lastInstallError = error
            downloadError = (error as? LocalizedError)?.errorDescription
                ?? "The update couldn't be installed. Try downloading it manually."
        }
    }

    /// The fallback (and what this class used to do outright): fetch the DMG and open it, so
    /// the user drags MacRazer across themselves.
    func downloadAndOpenDMG() async {
        guard !isBusy else { return }
        downloadError = nil
        phase = .downloading(0)
        do {
            let dmg = try await downloadDMG()
            phase = .idle
            NSWorkspace.shared.open(dmg)
        } catch {
            phase = .idle
            downloadError = "Download failed. Check your connection and try again."
        }
    }

    /// Downloads into a fresh temp directory, so the caller can delete the whole thing without
    /// worrying about what else might be sharing a filename in `/tmp`.
    private func downloadDMG() async throws -> URL {
        Self.sweepStaleDownloads()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacRazerUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let downloader = ProgressDownload(
            destination: dir.appendingPathComponent("MacRazer.dmg")
        ) { [weak self] fraction in
            Task { @MainActor in
                // Only while still downloading: a late callback must not drag the card back
                // out of "Installing…".
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(fraction)
            }
        }
        do {
            return try await downloader.run(from: dmgURL)
        } catch {
            // Nobody else knows about this directory yet, so a failed download has to take it
            // with it — otherwise every offline retry leaves one behind.
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// The manual-DMG path can't delete its own download — the user still has to open it — so
    /// nothing ever cleaned those up and each one left several megabytes behind for good.
    ///
    /// Only directories older than `staleAfter` go, and that age limit is the whole point
    /// rather than a tidiness detail: "everything earlier has served its purpose" is false for
    /// the download we handed to Finder a minute ago. The user may not have opened it yet, or
    /// may have it mounted — and deleting a mounted image's backing file leaves the volume
    /// broken, which is worse than the leak this is fixing.
    ///
    /// An image still mounted from more than an hour ago is the residual case, and the
    /// accepted trade: by then the user has either installed from it or forgotten it.
    private static let staleAfter: TimeInterval = 60 * 60

    private static func sweepStaleDownloads() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsSubdirectoryDescendants])) ?? []
        let cutoff = Date().addingTimeInterval(-staleAfter)
        for entry in entries where entry.lastPathComponent.hasPrefix("MacRazerUpdate-") {
            // No readable creation date: leave it alone. Erring towards a leak beats erring
            // towards deleting a file someone is using.
            guard let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                  created < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Same shape as `PermissionsModel.relaunch()`, and for the same reason: only quit once the
    /// replacement instance is actually up. The bundle on disk is already the new version, so a
    /// failed open must leave the running (old) app alive rather than turn "Update" into
    /// "Quit" — the user can relaunch by hand and get the new version.
    private func relaunch(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            Task { @MainActor in
                if app != nil, error == nil {
                    NSApp.terminate(nil)
                } else {
                    self.phase = .needsRestart
                }
            }
        }
    }

    private static func isNewer(_ remote: String, than local: String) -> Bool {
        VersionCompare.isNewer(remote, than: local)
    }

    // MARK: - Preview

    /// Pins the update card open for the `render-ui` preview, which otherwise only shows it on
    /// the rare day a real release is newer than the running build.
    func loadPreviewState(version: String = "9.9.9", phase: Phase = .idle, notes: String? = nil) {
        latestVersion = version
        self.phase = phase
        latestNotes = Self.parsed(notes.map { [RemoteRelease(version: version, body: $0)] } ?? [])
    }

    /// Pins the "Updated to …" card open for `render-ui updated`, which otherwise only appears
    /// on the one launch that follows an install.
    /// Two releases, because the point of the preview is the span.
    func loadPreviewSpan(_ releases: [RemoteRelease]) {
        justUpdatedTo = releases.first?.version
        installedNotes = Self.parsed(releases)
    }

    func loadPreviewUpdated(version: String = AppInfo.comparableVersion, notes: String? = nil) {
        justUpdatedTo = version
        installedNotes = Self.parsed(notes.map { [RemoteRelease(version: version, body: $0)] } ?? [])
    }
}

/// `URLSession.download(from:)` reports no progress at all, so this is the delegate form
/// wrapped back into async/await.
///
/// `@unchecked Sendable`, made safe by an actual lock rather than by an argument about
/// ordering: `continuation` and `session` are written by the caller and read on the session's
/// delegate queue, so nothing in this code establishes visibility between the two threads on
/// its own. `lock` does, and it also makes the resolve-exactly-once rule enforced rather than
/// merely true — `didFinishDownloadingTo` and `didCompleteWithError` both fire on success.
private final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    /// Last reported whole percent — the callback fires far more often than a progress bar can
    /// show, and each report costs a hop to the main actor.
    private var lastReportedPercent = -1

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
            lock.lock()
            self.continuation = continuation
            self.session = session
            lock.unlock()
            session.downloadTask(with: url).resume()
        }
    }

    /// Resolves once and once only.
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        // Outside the lock: invalidation drains the delegate queue, and resuming hands control
        // back to the awaiting task — neither belongs under a lock this narrow.
        session?.finishTasksAndInvalidate() // also breaks the session's retain on this delegate
        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64
    ) {
        guard expected > 0 else { return } // unknown length — leave the bar where it is
        let fraction = min(1, Double(written) / Double(expected))
        let percent = Int(fraction * 100)
        guard percent != lastReportedPercent else { return }
        lastReportedPercent = percent
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // A 404 body would otherwise be moved into place and only fail later, at mount time,
        // as the far less useful "the update couldn't be opened".
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        // The temp file is deleted the moment this returns, so the move has to happen here.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

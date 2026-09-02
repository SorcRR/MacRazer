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

    private let releaseAPIURL = URL(string: "https://api.github.com/repos/SorcRR/MacRazer/releases/latest")!
    private let dmgURL = URL(string: "https://github.com/SorcRR/MacRazer/releases/latest/download/MacRazer.dmg")!
    private let checkInterval: TimeInterval = 24 * 60 * 60

    private static let dismissedKey = "dismissedUpdateVersion"
    private static let lastCheckKey = "lastUpdateCheckDate"
    private static let lastFoundKey = "lastFoundUpdateVersion"

    private struct GitHubRelease: Decodable {
        let tag_name: String
    }

    private var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    var isBusy: Bool { phase != .idle }

    /// Whether the one-click "Update & Restart" path is available, or the card should offer
    /// the manual DMG instead.
    var canInstallInPlace: Bool { UpdateInstaller.canInstallInPlace }

    /// Checks at most once per `checkInterval`, regardless of how often this is called — safe to
    /// call on every launch and from a repeating timer.
    func checkForUpdatesIfDue() async {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < checkInterval {
            // Within the throttle window, surface what the last successful check already
            // found — otherwise a relaunch forgets a known update for up to a day.
            restoreLastFound()
            return
        }
        await checkForUpdatesNow()
    }

    /// Bypasses the throttle — used by `checkForUpdatesIfDue()` once due, and by the menu's
    /// "Check for Updates…".
    ///
    /// `userRequested` also drops a previous "dismiss": someone who goes looking for an update
    /// wants the answer, not the silence they asked for last week. Without it the menu item
    /// would be a no-op for exactly the people who dismissed the card and later changed their
    /// mind — the only ones who'd think to use it.
    func checkForUpdatesNow(userRequested: Bool = false) async {
        if userRequested { UserDefaults.standard.removeObject(forKey: Self.dismissedKey) }
        do {
            let (data, _) = try await URLSession.shared.data(from: releaseAPIURL)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remote = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            // Only a *successful* check counts against the daily throttle: a failed one
            // (offline right after wake is common) should retry on the next opportunity,
            // not silence update notices for a day.
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            UserDefaults.standard.set(remote, forKey: Self.lastFoundKey)
            let dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey)
            if Self.isNewer(remote, than: currentVersion), remote != dismissed {
                latestVersion = remote
            } else {
                latestVersion = nil
            }
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
              let found = UserDefaults.standard.string(forKey: Self.lastFoundKey) else { return }
        let dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey)
        if Self.isNewer(found, than: currentVersion), found != dismissed {
            latestVersion = found
        }
    }

    func dismiss(_ version: String) {
        UserDefaults.standard.set(version, forKey: Self.dismissedKey)
        latestVersion = nil
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
            downloadError = "Download failed — check your connection and try again."
        }
    }

    /// Downloads into a fresh temp directory, so the caller can delete the whole thing without
    /// worrying about what else might be sharing a filename in `/tmp`.
    private func downloadDMG() async throws -> URL {
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
    func loadPreviewState(version: String = "9.9.9", phase: Phase = .idle) {
        latestVersion = version
        self.phase = phase
    }
}

/// `URLSession.download(from:)` reports no progress at all, so this is the delegate form
/// wrapped back into async/await.
///
/// `@unchecked Sendable` under a stated discipline: every mutable field is touched only on the
/// session's own delegate queue, which is serial (`maxConcurrentOperationCount = 1`), except
/// for the two assignments made inside the continuation closure before the task is resumed —
/// i.e. before any callback can fire.
private final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
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
            self.continuation = continuation
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1 // serial: the state below has no lock
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    /// Resolves once and once only — `didFinishDownloadingTo` and `didCompleteWithError` both
    /// fire on a successful download.
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.finishTasksAndInvalidate() // also breaks the session's retain on this delegate
        session = nil
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

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The pure decision core of the automatic updater: given what we know, may we install this
/// version right now?
///
/// Split from the doing (`AppDelegate`) for the same reason as `LowBatteryAlertPolicy` and
/// `BatteryPollStateMachine` — no clock, no AppKit, no network — so every refusal and every
/// retry edge is unit-testable by replaying inputs. This one has the highest stakes of the
/// three: saying yes replaces the running application and relaunches it.
struct AutoInstallPolicy {
    /// Versions this session has already spent its one automatic attempt on. Keyed by version
    /// rather than a flag, so a *new* release is still tried after an older one failed.
    private var attempted = Set<String>()

    /// Everything the decision depends on, gathered by the caller. Passed in rather than read
    /// from globals so a test can pose any combination.
    struct Conditions {
        /// The newest version known to be available, or nil if we're up to date.
        let availableVersion: String?
        /// The user's "install updates automatically" setting.
        let enabled: Bool
        /// Whether an in-place swap is possible at all here.
        let canInstallInPlace: Bool
        /// An install or download is already running.
        let busy: Bool
        /// The popover is on screen. An install ends in a relaunch, and pulling the window out
        /// from under someone mid-click is worse than waiting for the next opportunity.
        let popoverVisible: Bool
    }

    /// The version to install now, or nil to do nothing. Records the attempt, so asking twice
    /// for the same version yields it at most once.
    ///
    /// Returns the version rather than a Bool because deciding and recording happen together:
    /// a caller that got `true` and then re-derived the version itself could act on a
    /// different one — or fail to unwrap it and drop a version already marked as spent.
    mutating func versionToInstall(_ c: Conditions) -> String? {
        guard let version = c.availableVersion,
              c.enabled, c.canInstallInPlace, !c.busy, !c.popoverVisible,
              !attempted.contains(version) else { return nil }
        attempted.insert(version)
        return version
    }

    /// An attempt failed for a reason that a later try could get past — the network dropped,
    /// the volume was busy. Puts the version back so the next opportunity retries it.
    ///
    /// The distinction matters because this app starts at login and runs for weeks: without
    /// it, one dropped connection means no automatic update until the user happens to
    /// relaunch, which may be next month.
    mutating func retryLater(_ version: String) { attempted.remove(version) }

    /// An attempt failed for a reason that will fail again — the payload isn't a newer
    /// MacRazer, or its signature is broken. Left recorded, so we don't re-download megabytes
    /// on every popover close to reach the same verdict.
    func isPermanent(_ error: Error) -> Bool {
        switch error as? UpdateInstallError {
        // Only these two are verdicts about the *payload*, and a second download of the same
        // release cannot change them.
        case .rejected, .signatureInvalid: return true
        // Everything else describes the environment at one moment and can come right: a busy
        // volume, a full disk that gets emptied, a half-written download, and `notWritable` —
        // a permissions repair or a security tool holding the bundle clears, and the user can
        // fix it themselves while the app keeps running. nil means it wasn't an install error
        // at all, i.e. the download failed, which is the transient case by definition.
        default: return false
        }
    }
}

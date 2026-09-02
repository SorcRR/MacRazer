// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import Security

/// The checks that decide whether the app inside a downloaded image may replace the running
/// one. Pure — no filesystem, no subprocesses — so every refusal is unit-testable.
///
/// This is the part that must not be got wrong: `installInPlace` deletes the installed bundle,
/// so anything that reaches the swap has to be a genuine, newer MacRazer.
enum UpdatePayloadCheck {
    enum Rejection: Equatable {
        /// Not the app we're updating (or an unreadable Info.plist).
        case wrongApp
        /// Same version or older. Nothing to gain, and a real bundle to lose.
        case notNewer(String)
    }

    static func reject(
        payloadBundleID: String?, payloadVersion: String?,
        expectedBundleID: String?, currentVersion: String
    ) -> Rejection? {
        // nil on either side is a refusal, never a match: a missing expectation must not
        // wave through a missing identifier.
        guard let expectedBundleID, let payloadBundleID, payloadBundleID == expectedBundleID,
              let payloadVersion, !payloadVersion.isEmpty else { return .wrongApp }
        guard VersionCompare.isNewer(payloadVersion, than: currentVersion) else {
            return .notNewer(payloadVersion)
        }
        return nil
    }
}

enum UpdateInstallError: LocalizedError, Equatable {
    case notInstalled
    case notWritable
    case mountFailed
    case noAppInImage
    case rejected(UpdatePayloadCheck.Rejection)
    case signatureInvalid
    case copyFailed(String)
    case swapFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Move MacRazer to your Applications folder first, then updates install themselves."
        case .notWritable:
            return "MacRazer can't write to its own folder — install the update manually."
        case .mountFailed:
            return "The downloaded update couldn't be opened. Try again."
        case .noAppInImage, .rejected(.wrongApp):
            return "The downloaded update didn't contain a MacRazer app. Try again."
        case .rejected(.notNewer(let version)):
            return "The download was version \(version), which isn't newer than what you're running."
        case .signatureInvalid:
            return "The downloaded update failed its signature check — it may be damaged."
        case .copyFailed, .swapFailed:
            return "The update downloaded but couldn't be installed. Install it manually instead."
        }
    }
}

/// Replaces the installed `MacRazer.app` with the one inside a downloaded DMG.
///
/// No Sparkle here: the app is self-signed and shipped as a plain drag-to-install image, so
/// there is no appcast and no EdDSA key to check a payload against. What this does instead is
/// precisely the manual install, automated — mount the image, confirm the app inside really is
/// a newer MacRazer whose signature is intact, then swap it into place atomically. The caller
/// relaunches.
///
/// Replacing a *running* bundle is safe because nothing is overwritten in place:
/// `replaceItemAt` moves the old bundle aside and unlinks it, and a running process keeps its
/// mapped executable alive through the unlink. The new copy only takes effect on relaunch,
/// which is the next thing that happens.
///
/// Swapping *in place* — same path, same signing identity — is also what keeps the two things
/// macOS has recorded against this app pointing at it: the Input Monitoring grant, without
/// which MacRazer can't read the mouse at all, and the `SMAppService` login item registered by
/// `LaunchAtLogin`. Installing to a new path would silently cost the user both.
enum UpdateInstaller {
    /// Where an in-place update would write, or nil when there is nothing installed to
    /// replace: `swift run`, a translocated copy, or the app running straight off the mounted
    /// DMG — the last of which is exactly the case where "drag me to Applications" is still
    /// the right answer.
    static var installTarget: URL? { AppLocation.installedBundleURL }

    /// Whether the one-click path is available at all. `/Applications` is group-writable by
    /// admin users; a standard user (or an app sitting in someone else's home) isn't, and is
    /// better sent to the DMG up front than failed halfway through.
    static var canInstallInPlace: Bool {
        guard let target = installTarget else { return false }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: target.path)
            && fm.isWritableFile(atPath: target.deletingLastPathComponent().path)
    }

    /// Mount → verify → swap. Blocking (subprocesses and a bundle copy); call it off the main
    /// thread. Returns the version now installed.
    @discardableResult
    static func installInPlace(
        dmg: URL, into target: URL, expectedBundleID: String?, currentVersion: String
    ) throws -> String {
        guard FileManager.default.isWritableFile(atPath: target.path) else {
            throw UpdateInstallError.notWritable
        }

        let mount = try attach(dmg)
        defer { detach(mount) }

        guard let payload = appBundle(atRootOf: mount) else { throw UpdateInstallError.noAppInImage }
        let info = NSDictionary(contentsOf: payload.appendingPathComponent("Contents/Info.plist"))
        let version = info?["CFBundleShortVersionString"] as? String
        if let rejection = UpdatePayloadCheck.reject(
            payloadBundleID: info?["CFBundleIdentifier"] as? String, payloadVersion: version,
            expectedBundleID: expectedBundleID, currentVersion: currentVersion
        ) {
            throw UpdateInstallError.rejected(rejection)
        }
        try verifySignature(of: payload)

        // A replacement directory is guaranteed to be on the target's own volume, which is what
        // makes the final swap a rename rather than a slow, interruptible cross-volume copy.
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(target.lastPathComponent)

        // ditto rather than FileManager.copyItem: it is the tool that copies app bundles
        // faithfully (ACLs, xattrs, symlinks), and a copy that loses any of those loses the
        // code signature with them.
        let copy = run("/usr/bin/ditto", [payload.path, staged.path])
        guard copy.status == 0 else { throw UpdateInstallError.copyFailed(copy.errorText) }
        stripQuarantine(from: staged)

        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } catch {
            throw UpdateInstallError.swapFailed(error.localizedDescription)
        }
        return version ?? currentVersion
    }

    // MARK: - Disk image

    private static func attach(_ dmg: URL) throws -> URL {
        // Checksum verification is deliberately left on (no `-noverify`): it is the cheapest
        // way to catch a truncated or corrupted download before anything is replaced.
        let result = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-plist"])
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(
                  from: result.output, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              // Several entities are listed (the whole-disk one has no mount point); the one
              // we want is the first that actually mounted.
              let mount = entities.compactMap({ $0["mount-point"] as? String })
                  .first(where: { !$0.isEmpty })
        else { throw UpdateInstallError.mountFailed }
        return URL(fileURLWithPath: mount)
    }

    private static func detach(_ mount: URL) {
        guard run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]).status != 0 else { return }
        // Something (Spotlight, Finder, the copy we just made) is still holding the volume.
        // Force it rather than leaving a phantom disk mounted for the rest of the session.
        _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
    }

    /// The single `.app` at the image's root. Matched by extension, not by name, so a renamed
    /// release asset still installs — the identity checks are the Info.plist's job.
    private static func appBundle(atRootOf mount: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: mount, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return entries.first { $0.pathExtension == "app" }
    }

    // MARK: - Integrity

    /// Seal integrity, *not* trust: MacRazer is self-signed, so a Gatekeeper assessment
    /// (`spctl --assess`) would reject every legitimate release. What matters here is that the
    /// bundle about to replace a working app is byte-for-byte what was signed.
    ///
    /// The signing *identity* is deliberately not compared against the running app's. It would
    /// catch nothing an HTTPS fetch from the project's own releases doesn't already cover, and
    /// it would brick updates for every existing user the day the maintainer's self-signed
    /// certificate is regenerated. The cost of an identity change is a re-prompt for Input
    /// Monitoring, which is recoverable; a stuck updater isn't.
    private static func verifySignature(of app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
                  == errSecSuccess
        else { throw UpdateInstallError.signatureInvalid }
    }

    /// Best-effort: a quarantined replacement would make macOS re-run Gatekeeper on a
    /// self-signed app, i.e. greet the user with the scary first-launch dialog after an update
    /// they didn't even have to click through. Nothing here downloads via LaunchServices, so
    /// the attribute normally isn't set at all — this is belt and braces.
    private static func stripQuarantine(from bundle: URL) {
        let name = "com.apple.quarantine"
        removexattr(bundle.path, name, XATTR_NOFOLLOW)
        guard let walker = FileManager.default.enumerator(
            at: bundle, includingPropertiesForKeys: nil, options: []) else { return }
        for case let url as URL in walker {
            removexattr(url.path, name, XATTR_NOFOLLOW)
        }
    }

    // MARK: - Subprocess

    private struct ProcessResult {
        let status: Int32
        let output: Data
        let errorText: String
    }

    private static func run(_ tool: String, _ arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, output: Data(), errorText: error.localizedDescription)
        }
        // Drain before waiting: hdiutil's plist is comfortably larger than a pipe buffer, and
        // waiting first would deadlock against a child blocked on a full pipe.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus, output: outData,
            errorText: String(data: errData, encoding: .utf8) ?? "")
    }
}

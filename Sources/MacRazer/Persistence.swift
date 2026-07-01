// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// One versioned JSON file in Application Support, shared by the per-device data stores
/// (battery history, charge cycles, discharge curve). Adds what the bare
/// `Data.write`/`JSONDecoder` calls it replaced were missing:
/// - **atomic writes** — a crash mid-write must not truncate the existing file; the next
///   launch would silently decode nothing and the following save would overwrite what was
///   left of the data;
/// - **a version envelope** — so a future format change degrades to a clean re-learn
///   instead of a silent decode failure indistinguishable from "no data yet";
/// - **write throttling** — the histories update every poll tick (4-15s); rewriting a
///   potentially hundreds-of-KB file that often is disk churn for a few bytes of change.
///   Losing a few seconds of tail on an unclean quit is an acceptable trade (`saveNow`
///   covers clean quits and boundaries worth persisting immediately).
final class VersionedFileStore<T: Codable> {
    private let url: URL
    private let version: Int
    private let saveInterval: TimeInterval
    private var lastSaveAt = Date.distantPast

    /// `directory` overrides the default Application Support location — used by tests so
    /// they never touch (or depend on) the real user data.
    init(filename: String, version: Int, saveInterval: TimeInterval = 30, directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacRazer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(filename)
        self.version = version
        self.saveInterval = saveInterval
    }

    private struct Envelope: Codable {
        let version: Int
        let payload: T
    }

    /// nil when the file is missing, unreadable, or from a different format version.
    /// `migratingLegacy` additionally accepts a pre-envelope bare `T` — the on-disk format
    /// before versioning existed — so existing users' data survives the upgrade. Pass false
    /// where the legacy data is semantically invalid and must be discarded, not migrated.
    func load(migratingLegacy: Bool = false) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           envelope.version == version {
            return envelope.payload
        }
        if migratingLegacy, let bare = try? JSONDecoder().decode(T.self, from: data) {
            return bare
        }
        return nil
    }

    /// Throttled write — a no-op within `saveInterval` of the last write.
    func save(_ value: T) {
        guard Date().timeIntervalSince(lastSaveAt) >= saveInterval else { return }
        saveNow(value)
    }

    /// Unconditional write, bypassing the throttle — for boundaries worth persisting
    /// immediately and for app termination, where the in-memory tail would otherwise be lost.
    func saveNow(_ value: T) {
        lastSaveAt = Date()
        guard let data = try? JSONEncoder().encode(Envelope(version: version, payload: value)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

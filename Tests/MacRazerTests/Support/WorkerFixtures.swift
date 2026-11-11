// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The fixtures that are the contract with the Worker: the app's tests write them, and the
/// Worker's CI (SorcRR/macrazer-worker, scripts/fixtures.mjs) fetches them from this
/// directory. Moving it means changing that script and `exclude` in Package.swift too.
enum WorkerFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/worker")

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
}

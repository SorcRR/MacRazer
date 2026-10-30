// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit

/// Opens a second instance of a bundle and reports, on the main actor, whether it launched.
/// Shared by the update install and the Input Monitoring "Quit & Relaunch".
///
/// Both callers are `@MainActor` classes, and that is exactly what made this crash. A closure
/// written inline there inherits main-actor isolation under Swift 6, so the compiler puts a
/// runtime executor check at its top. LaunchServices calls the completion handler on its own
/// open queue, the check fails, and the process traps with SIGTRAP after the new instance is
/// already up. So the handler here is `@Sendable` and nonisolated, captures nothing but the
/// callback, and hops to the main actor itself.
enum AppRelaunch {
    /// The completion handler LaunchServices is given. Called on an arbitrary queue.
    typealias Completion = @Sendable (NSRunningApplication?, (any Error)?) -> Void
    /// Stands in for `NSWorkspace.openApplication` so tests can call back off the main thread.
    typealias Opener = @Sendable (URL, NSWorkspace.OpenConfiguration, @escaping Completion) -> Void

    static let workspaceOpener: Opener = { url, config, completion in
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: completion)
    }

    /// `launched` is true only when the new instance is running. Callers quit on true and
    /// stay alive on false, so a failed open never turns "Relaunch" into plain "Quit".
    nonisolated static func openNewInstance(
        of url: URL,
        opener: Opener = workspaceOpener,
        then launched: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        opener(url, config) { @Sendable app, error in
            let ok = app != nil && error == nil
            Task { @MainActor in launched(ok) }
        }
    }
}

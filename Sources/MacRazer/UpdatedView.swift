// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// Shown once, on the first launch after the version changes: the update worked, and this is
/// what it brought.
///
/// The popover's "Updated to …" card says the same thing, but only to someone who opens the
/// popover, which after a relaunch nobody has a reason to do. A window is the confirmation
/// that "Update & Restart" actually finished.
struct UpdatedView: View {
    @ObservedObject var updateChecker: UpdateChecker
    /// Not optional, for the same reason as `AboutView.onDone`.
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            notes
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.razerGreen)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    /// `AppInfo.displayVersion`, not `justUpdatedTo`, for the reason given on the popover's
    /// card: the latter is the comparable version, "0" for a dev build.
    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(Color.razerGreenBright.opacity(0.20))
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.razerGreenBright)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Updated to \(AppInfo.displayVersion)").font(.system(size: 20, weight: .semibold))
                Text("MacRazer was updated successfully.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Notes usually come from the cache the previous version filled when it found this
    /// release. When they don't, the launch check is fetching them, and the view fills in when
    /// it returns rather than opening onto nothing.
    @ViewBuilder
    private var notes: some View {
        if !updateChecker.installedNotes.isEmpty {
            Text("What's new").font(.system(size: 13, weight: .semibold))
            ScrollView {
                ReleaseNotesList(releases: updateChecker.installedNotes)
                    .padding(.trailing, 8)
            }
            .frame(height: 320)
        } else if updateChecker.isChecking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching release notes…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        } else {
            Link("Read the release notes on GitHub", destination: ProjectLinks.latestRelease)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.razerGreen)
        }
    }
}

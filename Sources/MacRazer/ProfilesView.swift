// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// Manage page for saved profiles: rename, set active, delete. Reached via "Manage…" on the
/// main page's profiles card; quick-switching itself happens from that card directly, so this
/// page is only needed once there's more than one profile to curate.
struct ProfilesView: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    var onBack: (() -> Void)?

    @State private var renamingID: UUID?
    @State private var renameText: String = ""
    @State private var pendingDeleteID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if controller.profiles.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(controller.profiles) { profile in
                        row(for: profile)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: onBack == nil ? 440 : 320)
        .confirmationDialog("Delete this profile?", isPresented: Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID { controller.deleteProfile(id) }
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let onBack { BackButton(action: onBack) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Profiles").font(.system(size: 16, weight: .semibold))
                Text("Saved DPI, lighting and button setups you can switch between.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No profiles yet").font(.system(size: 12, weight: .medium))
            Text("Use the + button on the main page to save your current setup as a profile.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(for profile: MouseProfile) -> some View {
        let active = profile.id == controller.activeProfileID
        return HStack(spacing: 10) {
            Button {
                controller.applyProfile(profile, remapper: remapper)
            } label: {
                ZStack {
                    Circle().fill(active ? Color.razerGreen : Color.primary.opacity(0.10))
                    if active {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(active ? "Active" : "Apply this profile")

            VStack(alignment: .leading, spacing: 1) {
                if renamingID == profile.id {
                    TextField("Name", text: $renameText, onCommit: {
                        controller.renameProfile(profile.id, to: renameText)
                        renamingID = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                } else {
                    Text(profile.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                }
                Text(profile.summary).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)

            Button {
                renameText = profile.name
                renamingID = profile.id
            } label: {
                Image(systemName: "pencil").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                pendingDeleteID = profile.id
            } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.batteryLow)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(active ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

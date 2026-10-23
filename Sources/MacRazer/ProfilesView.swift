// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// Manage page for saved snapshot profiles: rename, set active, delete. Reached via "Manage…"
/// on the main page's profiles card; quick-switching itself happens from that card directly,
/// so this page is only needed once there's more than one profile to curate. A mouse whose
/// slots are its profiles lists them in the card itself (`SlotProfilesList`).
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
                if !controller.connected {
                    Text("Mouse offline. You can rename or delete profiles, but not apply them.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else if controller.profileApplyFailed {
                    Text("Couldn't apply that. The mouse isn't responding.")
                        .font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
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
                if let id = pendingDeleteID { controller.deleteProfile(id, remapper: remapper) }
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Esc cancels an in-progress rename (the field's onExitCommand), not the page.
            if let onBack { BackButton(action: onBack, escapes: renamingID == nil) }
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

    /// Says which onboard slot holds the profile, on mice that keep profiles themselves.
    private func summary(for profile: MouseProfile) -> String {
        guard controller.supportsOnboardSlots, let slot = profile.onboardSlot else { return profile.summary }
        return profile.summary + " · In mouse, slot \(slot)"
    }

    private func row(for profile: MouseProfile) -> some View {
        let active = profile.id == controller.activeProfileID
        let renaming = renamingID == profile.id
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(active ? Color.razerGreen : Color.primary.opacity(0.10))
                if active {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.onRazerGreen)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Name", text: $renameText, onCommit: {
                        controller.renameProfile(profile.id, to: renameText)
                        renamingID = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .onExitCommand { renamingID = nil } // Esc cancels, like any macOS rename
                } else {
                    Text(profile.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                }
                Text(summary(for: profile)).font(.system(size: 10.5)).foregroundStyle(.secondary)
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
        // The whole row applies (the old 20pt circle was a needlessly small target); the
        // pencil/trash Buttons take precedence over this tap, and it's inert while a
        // rename is in progress or the mouse is offline.
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            guard controller.connected, !renaming else { return }
            controller.applyProfile(profile, remapper: remapper)
        }
        .help(active ? "Active" : (controller.connected ? "Apply this profile" : "Mouse offline"))
    }
}

/// The profiles of a mouse whose onboard slots are its profiles (`MouseController.usesSlotProfiles`),
/// listed in the main page's Profiles card: tap one to switch to it, rename it, reset it to
/// factory, delete it (never slot 1), or add one in the next free slot.
struct SlotProfilesList: View {
    @ObservedObject var controller: MouseController

    @State private var renameText = ""
    /// The slot being renamed, and the one a reset or delete waits to be confirmed for.
    @State private var renamingSlot: Int?
    @State private var pendingResetSlot: Int?
    @State private var pendingDeleteSlot: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.onboardSlotList, id: \.self) { slotRow($0) }
            if controller.onboardSlotList.count < OnboardSlots.maxSlots {
                Button {
                    let next = OnboardSlots.nextFreeSlot(existing: Set(controller.onboardSlotList)) ?? OnboardSlots.maxSlots
                    controller.addSlotProfile(name: SlotNames.defaultName(next))
                } label: {
                    Label("Add Profile", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.razerGreenText)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!controller.connected)
                .help("Adds a profile as the mouse comes from the factory")
            }
            if !controller.connected {
                Text("Mouse offline. You can rename profiles, but not switch or change them.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else if controller.profileApplyFailed {
                Text("Couldn't do that. The mouse isn't responding.")
                    .font(.system(size: 10.5)).foregroundStyle(Color.batteryLow)
            }
        }
        .confirmationDialog("Reset this profile to factory settings?", isPresented: Binding(
            get: { pendingResetSlot != nil },
            set: { if !$0 { pendingResetSlot = nil } }
        ), titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                if let slot = pendingResetSlot { controller.resetSlotProfile(slot) }
                pendingResetSlot = nil
            }
            Button("Cancel", role: .cancel) { pendingResetSlot = nil }
        } message: {
            Text("Its DPI, lighting and button remaps go back to how the mouse came.")
        }
        .confirmationDialog("Delete this profile from the mouse?", isPresented: Binding(
            get: { pendingDeleteSlot != nil },
            set: { if !$0 { pendingDeleteSlot = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let slot = pendingDeleteSlot { controller.deleteSlotProfile(slot) }
                pendingDeleteSlot = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteSlot = nil }
        }
    }

    private func slotRow(_ slot: Int) -> some View {
        let active = slot == controller.activeOnboardSlot
        let renaming = renamingSlot == slot
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(active ? Color.razerGreen : Color.primary.opacity(0.10))
                if active {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.onRazerGreen)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Name", text: $renameText, onCommit: {
                        controller.renameSlotProfile(slot, to: renameText)
                        renamingSlot = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .onExitCommand { renamingSlot = nil }
                } else {
                    Text(controller.slotName(slot)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                }
                Text(active ? "Slot \(slot) · Active" : "Slot \(slot)")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)

            Button {
                renameText = controller.slotName(slot)
                renamingSlot = slot
            } label: {
                Image(systemName: "pencil").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Rename")

            Button {
                pendingResetSlot = slot
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!controller.connected)
            .help("Reset to factory settings")

            if slot != Int(OnboardSlots.first) {
                Button {
                    pendingDeleteSlot = slot
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.batteryLow)
                .disabled(!controller.connected)
                .help("Delete from the mouse")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(active ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            guard controller.connected, !renaming else { return }
            controller.switchToSlot(slot)
        }
        .help(active ? "Active" : (controller.connected ? "Switch to this profile" : "Mouse offline"))
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

enum DPIShortcutModifiers {
    static func hidValue(from flags: CGEventFlags) -> UInt8 {
        var value: UInt8 = 0
        if flags.contains(.maskControl) { value |= 0x01 }
        if flags.contains(.maskShift) { value |= 0x02 }
        if flags.contains(.maskAlternate) { value |= 0x04 }
        if flags.contains(.maskCommand) { value |= 0x08 }
        return value
    }
}

struct RemapView: View {
    @ObservedObject var remapper: ButtonRemapper
    var controller: MouseController?
    var onBack: (() -> Void)?
    /// The popover's sub-page width; the window's is 440.
    var width: CGFloat = 440
    /// The two-column popover: the buttons on the left, the DPI button and notes on the right.
    var twoColumns = false
    /// For the `render-remap gesture` preview: the button whose gesture editor is open.
    var previewGestureEditor: Int?
    @State private var recordingButton: Int?
    @State private var recordingDpiCycleShortcut = false
    @State private var recorderError: String?
    /// The button whose gesture editor is open.
    @State private var editingGesture: Int?
    /// The slot of `editingGesture` a custom shortcut is being recorded for.
    @State private var recordingSlot: GestureSlot?
    /// The open gesture editor's height, so the page is never shorter than it (`body`).
    @State private var gestureEditorHeight: CGFloat = 0

    private var buttons: [Int] {
        Array(remapper.seenButtons.union(remapper.suggestedButtons).union(remapper.mappings.keys)).sorted()
    }

    private var isRecording: Bool { recordingButton != nil || recordingDpiCycleShortcut || recordingSlot != nil }

    /// The gesture editor's button, while it is still a gesture (applying a profile can
    /// change that with the editor open).
    private var gestureEditorButton: Int? {
        editingGesture.flatMap { remapper.gestureBindings(for: $0) != nil ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if twoColumns {
                // What to do and how remapping works on the left; the mappings on the right.
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        notices
                        footer
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 14) {
                        buttonList
                        dpiAndModelNotes
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                notices
                buttonList
                dpiAndModelNotes
                footer
            }
        }
        .padding(18)
        .frame(width: width)
        // Room for the gesture editor when the page has only a button or two, and at least its
        // own height with a margin, so its checkbox and a long explanation are never clipped at
        // the top and bottom. The editor's height doesn't depend on the page's, so this
        // settles at once.
        .frame(minHeight: gestureEditorButton == nil ? nil : max(400, gestureEditorHeight + 24), alignment: .top)
        .onAppear {
            remapper.refreshAccessibility(prompt: false)
            if let previewGestureEditor { editingGesture = previewGestureEditor }
        }
        .overlay { if let button = gestureEditorButton { gestureEditor(button) } }
        // A button that stopped being a gesture under the open editor closes it for good, so
        // it can't pop up again if the button becomes one later.
        .onChange(of: gestureEditorButton) { _, now in
            if now == nil {
                editingGesture = nil
                recordingSlot = nil
            }
        }
        // After the gesture editor, so recording one of its slots shows on top of it.
        .overlay { if isRecording { recorderOverlay } }
        .background { if let controller { SideButtonCheckTrigger(controller: controller) } }
    }

    /// The permission banner, or the paused note and the "press a button" hint.
    @ViewBuilder private var notices: some View {
        if let controller { SideButtonResetNotice(controller: controller) }
        if !remapper.remappingPermissionsGranted {
            accessibilityBanner
        } else {
            if remapper.remappingPaused { pausedNote }
            if remapper.showsCompetingApps { competingAppsNote }
            detectionHint
        }
    }

    /// Another app can take a button's clicks before MacRazer sees them, and then the button
    /// never shows up here. Naming the app saves a support email.
    private var competingAppsNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.batteryMid)
            Text(Self.competingAppsText(remapper.competingTapApps))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.batteryMid.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    nonisolated static func competingAppsText(_ apps: [String]) -> String {
        let list = ListFormatter.localizedString(byJoining: apps)
        let pronoun = apps.count == 1 ? "it" : "them"
        return "If a side button doesn't show up here when you press it, \(list) may be taking "
            + "its clicks. Quit \(pronoun) and try again."
    }

    /// How the gesture editor says a gesture is made. A mouse button's is held while the mouse
    /// moves. The DPI button of a mouse with private keys (`ButtonRemapper.supportsDpiPrivateKeys`)
    /// starts its gesture only once the firmware has recognised a long press, about a second in,
    /// its short press is the click, and a long press let go without a swipe is Hold.
    /// `followsPointer`: the four system swipes follow the pointer on this Mac
    /// (`DockSwipe.isSupported`), so the text says so. The editor passes
    /// `ButtonRemapper.systemSwipesFollowPointerHere`, which is also off while its checkbox is
    /// (`followPointerToggle`): the four are then shortcuts, as the rest of the text already
    /// covers.
    nonisolated static func gestureEditorExplanation(longPress: Bool = false,
                                                     followsPointer: Bool = DockSwipe.isSupported) -> String {
        let swipes = "Mission Control and the Spaces follow the pointer while you hold it, and so does App Exposé "
            + "with its trackpad gesture on. "
        return longPress
            ? "Hold the DPI button until the gesture starts (about a second), then move the mouse up, "
                + "down, left or right. " + (followsPointer ? swipes : "") + "A short press does Click. "
                + "Holding it without moving does Hold when you let go. " + dpiButtonTimingNote
            : "Hold the button and move the mouse up, down, left or right. "
                + (followsPointer ? swipes : "")
                + "Press and release it without moving to click."
    }

    /// Why a gesture on this DPI button can't start the instant it is pressed, said where the
    /// button is set up: the mouse itself only reports it at those two moments (seen on the Cobra
    /// HyperSpeed; Synapse gets nothing earlier either), which no setting changes.
    nonisolated static let dpiButtonTimingNote = "This mouse only reports its DPI button when a short "
        + "press is let go, or about a second into a hold, so nothing can start the instant you press "
        + "it. For a gesture that starts at once, use a side button or the wheel click."

    /// The help under the DPI button's menu. On a mouse with private keys it says how MacRazer
    /// takes the button over while it runs, and gives it back, and how a gesture is made there.
    /// On any other (the Basilisk V3 X) it is the F20 bridge's text, as it always was.
    nonisolated static func dpiButtonHelpText(privateKeys: Bool) -> String {
        guard privateKeys else {
            return "Media and Double Click require MacRazer running with Accessibility and Input Monitoring "
                + "enabled. They reserve F20 while active; select DPI Cycle (default) to restore the original button."
        }
        return "Media, Double Click, Launchpad, Gesture and keys the mouse can't type itself need MacRazer "
            + "running, with Accessibility and Input Monitoring on. While one is set, the mouse is switched "
            + "to a mode where MacRazer handles the DPI button while it runs. It goes back to normal when "
            + "MacRazer quits or DPI Cycle (default) is chosen. "
            + gestureEditorExplanation(longPress: true, followsPointer: false)
    }

    /// The gesture editor's checkbox for `ButtonRemapper.systemSwipesFollowPointer`. Short
    /// enough for one line at the editor's width beside its box.
    nonisolated static let followPointerToggleTitle = "Mission Control and Spaces follow the pointer"

    /// The DPI button's binding and model notes.
    @ViewBuilder private var dpiAndModelNotes: some View {
        if let controller {
            DpiCycleBindingSection(controller: controller, remapper: remapper,
                                   onRecordShortcut: {
                                       recorderError = nil
                                       recordingDpiCycleShortcut = true
                                   },
                                   // Shown once the gesture is saved (`gestureEditorButton`), at
                                   // once when it already was one.
                                   onGesture: { editingGesture = ButtonRemapper.dpiButton })
        }
        if remapper.hasMultiFunctionTrigger { multiFunctionTriggerNote }
    }

    private func endRecording() {
        recordingButton = nil
        recordingDpiCycleShortcut = false
        recordingSlot = nil
        recorderError = nil
    }

    /// Who the recorded shortcut is for: "DPI Button", "Back (4)", "Button 6, Swipe Up".
    private var recordingTarget: String {
        if recordingDpiCycleShortcut { return ButtonRemapper.label(for: ButtonRemapper.dpiButton) }
        if let slot = recordingSlot, let button = editingGesture {
            return "\(ButtonRemapper.label(for: button)), \(slot.title)"
        }
        return recordingButton.map { ButtonRemapper.label(for: $0) } ?? ""
    }

    private var recorderOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture { endRecording() }
            VStack(spacing: 14) {
                Text("Press a key combination").font(.system(size: 14, weight: .semibold))
                Text("for \(recordingTarget)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                KeyRecorderView(onCapture: { keyCode, flags, display in
                    let action = RemapAction.keystroke(keyCode: keyCode, modifiers: flags.rawValue, name: display)
                    if let b = recordingButton {
                        remapper.setAction(action, for: b)
                    }
                    if let slot = recordingSlot, let b = editingGesture {
                        remapper.setGestureAction(action, for: slot, of: b)
                    }
                    if recordingDpiCycleShortcut {
                        // The mouse types it itself when it can. Otherwise, on a mouse with
                        // private keys, MacRazer does, through driver mode; the Basilisk takes
                        // only the keys it can type, as before.
                        if let controller, remapper.configureDpiButton(action, controller: controller) {
                            recordingDpiCycleShortcut = false
                            recorderError = nil
                        } else if remapper.supportsDpiPrivateKeys {
                            recorderError = "The mouse can't type this key itself, and MacRazer needs "
                                + "Accessibility to type it for the mouse."
                        } else {
                            recorderError = "This key is not supported by the mouse's Bluetooth shortcut format."
                        }
                    } else {
                        recordingButton = nil
                        recordingSlot = nil
                    }
                }, onCancel: { endRecording() })
                .frame(height: 46)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.razerGreen, lineWidth: 1.5))
                if let recorderError {
                    Text(recorderError).font(.system(size: 10)).foregroundStyle(Color.batteryMid)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Cancel") { endRecording() }
            }
            .padding(20)
            .frame(width: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// A gesture button's actions, over the page like the key recorder: Click, Hold where the
    /// button has one (`ButtonRemapper.gestureSlots(of:)`), and the four swipes, then whether
    /// the system swipes follow the pointer where they can (`followPointerToggle`). Each change
    /// is saved as it's made, so Done only closes it.
    private func gestureEditor(_ button: Int) -> some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture { editingGesture = nil }
            VStack(spacing: 12) {
                VStack(spacing: 4) {
                    Text("\(ButtonRemapper.label(for: button)) Gesture").font(.system(size: 14, weight: .semibold))
                    Text(Self.gestureEditorExplanation(
                        longPress: button == ButtonRemapper.dpiButton && remapper.supportsDpiPrivateKeys,
                        followsPointer: remapper.systemSwipesFollowPointerHere))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(Array(remapper.gestureSlots(of: button).enumerated()), id: \.element) { index, slot in
                        if index > 0 { Divider().overlay(Color.primary.opacity(0.1)) }
                        HStack(spacing: 8) {
                            Image(systemName: slot.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.razerGreenText)
                                .frame(width: 16)
                            Text(slot.title).font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 6)
                            // A slot's None does nothing: there is no click to let through. The
                            // DPI button of a mouse with private keys offers DPI Cycle beside it.
                            RemapActionMenu(label: remapper.gestureSlotLabel(slot, of: button),
                                            noneTitle: RemapAction.passthrough.label,
                                            leadingChoices: remapper.gestureSlotLeadingChoices(of: button),
                                            ownClick: ButtonRemapper.originalClick(for: button),
                                            onPick: { remapper.setGestureAction($0, for: slot, of: button) },
                                            onRecord: { recorderError = nil; recordingSlot = slot })
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                }
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                // Only where the Dock takes these swipes: anywhere else the four are shortcuts
                // whatever it says.
                if DockSwipe.isSupported { followPointerToggle }
                // Esc belongs to the key recorder while it's up, as with the Back button.
                Button("Done") { editingGesture = nil }
                    .keyboardShortcut(isRecording ? nil : KeyboardShortcut.cancelAction)
            }
            .padding(20)
            .frame(width: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { gestureEditorHeight = $0 }
        }
    }

    /// Whether Mission Control, App Exposé and the Spaces follow the pointer
    /// (`ButtonRemapper.systemSwipesFollowPointer`). One setting for every gesture button, so it
    /// sits under the slots rather than among them. A checkbox: a switch beside the label
    /// wouldn't leave it one line at the editor's width.
    private var followPointerToggle: some View {
        Toggle(isOn: $remapper.systemSwipesFollowPointer) {
            Text(Self.followPointerToggleTitle)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Esc belongs to the key recorder while it's up: it cancels the recording. And to
            // the gesture editor while that's open: it closes the editor.
            if let onBack {
                BackButton(action: onBack, escapes: !isRecording && gestureEditorButton == nil)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Configure Buttons").font(.system(size: 16, weight: .semibold))
                Text("Remap your mouse's extra buttons.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(remapper.accessibilityGranted ? "Button event tap unavailable" : "Accessibility permission required", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .medium))
            Text(remapper.accessibilityGranted
                 ? "macOS did not create the event tap. Re-check the exact MacRazer app in System Settings, then press Re-check."
                 : "Button remapping intercepts mouse events, which needs Accessibility access. Enable MacRazer in System Settings, then press Re-check.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Accessibility Settings") { remapper.openAccessibilitySettings() }
                Button("Re-check") { remapper.refreshAccessibility(prompt: true) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Mappings don't fire while the mouse is offline (see `ButtonRemapper.remappingPaused`);
    /// without this note, a working detection row next to non-firing mappings looks broken.
    private var pausedNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle").foregroundStyle(Color.batteryMid)
            Text("Mouse offline. Remapping is paused until it reconnects.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.batteryMid.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var detectionHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.click.2").foregroundStyle(Color.razerGreenText)
            if let b = remapper.lastDetectedButton {
                Text("Detected: \(ButtonRemapper.label(for: b))")
                    .font(.system(size: 12, weight: .medium))
                    .contentTransition(.opacity)
            } else {
                Text("Press a button on your mouse to identify it…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var buttonList: some View {
        if buttons.isEmpty {
            Text("No extra buttons detected yet. Click each one you want to remap.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(buttons.enumerated()), id: \.element) { index, button in
                    if index > 0 { Divider().overlay(Color.primary.opacity(0.1)) }
                    buttonRow(button)
                }
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func buttonRow(_ button: Int) -> some View {
        HStack(spacing: 8) {
            Text(ButtonRemapper.label(for: button))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 6)
            // Choosing Gesture… again reopens the editor, with the button's choices kept.
            RemapActionMenu(label: remapper.actionLabel(for: button),
                            onPick: { remapper.setAction($0, for: button) },
                            onRecord: { recordingButton = button },
                            onGesture: {
                                remapper.makeGesture(button)
                                editingGesture = button
                            })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        Text("Remapping works while this app is running and the mouse is connected; it "
             + "pauses when the mouse goes offline. macOS can't tell which mouse sent a "
             + "click, so while connected the mappings apply to matching buttons on any "
             + "pointing device. Mappings are saved automatically.")
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The Basilisk V3 X's Multi-function trigger (`RazerDevices.hasMultiFunctionTrigger`).
    private var multiFunctionTriggerNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Color.batteryMid)
            Text("The Multi-function/Hypershift trigger remains an onboard modifier. This firmware does not expose it for Bluetooth remapping. DPI Cycle can be configured through the mouse's Bluetooth control channel.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.batteryMid.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The actions a button, or one of a gesture's slots, can be set to. One menu for every place
/// that picks an action, so their lists can't drift apart.
private struct RemapActionMenu: View {
    /// The current action's label, shown as the menu's title.
    let label: String
    /// A button's "None" lets its click through. A gesture slot's does nothing at all.
    var noneTitle = "None (default)"
    /// The choices at the top of the menu, before Shortcut: None (`noneTitle`) everywhere, and
    /// DPI Cycle beside it in the DPI button's gesture on a mouse with private keys
    /// (`ButtonRemapper.gestureSlotLeadingChoices`).
    var leadingChoices: [RemapAction] = [.passthrough]
    /// The button's own click (`ButtonRemapper.originalClick`), offered under Mouse: a
    /// gesture's slot can't pass the click through, only post it again.
    var ownClick: RemapAction?
    let onPick: (RemapAction) -> Void
    let onRecord: () -> Void
    /// Offers Gesture… when set. Never inside a gesture: one nested in another can't fire.
    var onGesture: (() -> Void)?
    /// More choices under Mouse, after the ones every button has: the DPI button's own
    /// functions (Left Click, Scroll Up, …), which no `RemapAction` names.
    var extraMouseChoices: [RemapMenuChoice] = []
    /// Disables the choices only MacRazer can carry out (Double Click, Media, Launchpad,
    /// Gesture…). For the DPI button while the event tap isn't available: the mouse runs its
    /// other choices.
    var softwareChoicesDisabled = false
    /// Lists Launchpad. Not for the Basilisk's DPI button, whose F20 bridge takes only what it
    /// always has.
    var offersLaunchpad = true
    var width: CGFloat = 150

    private static let middleClick = RemapAction.mouseButton(button: 2, name: "Middle Click")

    var body: some View {
        Menu {
            ForEach(leadingChoices, id: \.label) { action in
                Button(action == .passthrough ? noneTitle : action.label) { onPick(action) }
            }
            Menu("Shortcut") {
                ForEach(ButtonRemapper.presets) { p in
                    Button(p.name) { onPick(p.action) }
                    // Next to the other system presets, though it opens an app rather than
                    // typing a shortcut: it has none by default.
                    if offersLaunchpad, p.id == ButtonRemapper.launchpadMenuAnchor {
                        Button(RemapAction.launchpad.label) { onPick(.launchpad) }
                            .disabled(softwareChoicesDisabled)
                    }
                }
            }
            Menu("Mouse") {
                Button("Middle Click") { onPick(Self.middleClick) }
                if let ownClick, ownClick != .passthrough, ownClick != Self.middleClick {
                    Button(ownClick.label) { onPick(ownClick) }
                }
                Button("Double Click") { onPick(.doubleClick) }
                    .disabled(softwareChoicesDisabled)
                if !extraMouseChoices.isEmpty {
                    Divider()
                    ForEach(extraMouseChoices) { choice in
                        Button(choice.title, action: choice.pick)
                    }
                }
            }
            Menu("Media") {
                ForEach(ButtonRemapper.mediaOptions, id: \.code) { opt in
                    Button(opt.name) { onPick(.mediaKey(code: opt.code, name: opt.name)) }
                }
            }
            .disabled(softwareChoicesDisabled)
            if let onGesture {
                Button("Gesture…", action: onGesture)
                    .disabled(softwareChoicesDisabled)
            }
            Divider()
            Button("Record Custom Shortcut…", action: onRecord)
        } label: {
            Text(label)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .frame(width: width)
    }
}

/// A choice `RemapActionMenu` adds for something a `RemapAction` can't name.
private struct RemapMenuChoice: Identifiable {
    let title: String
    let pick: () -> Void
    var id: String { title }
}

private extension GestureSlot {
    var symbol: String {
        switch self {
        case .click: "cursorarrow.click"
        case .hold: "cursorarrow.click.badge.clock"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        }
    }
}

/// Reads the side buttons when the page opens and again whenever the mouse comes back, as a
/// disconnect clears what was read. A background view: the notice is empty until something
/// was found, and an empty view never appears.
private struct SideButtonCheckTrigger: View {
    @ObservedObject var controller: MouseController

    var body: some View {
        Color.clear
            .onAppear { controller.checkSideButtonsIfSupported() }
            .onChange(of: controller.checksSideButtons) { _, now in if now { controller.checkSideButtonsIfSupported() } }
    }
}

/// Side buttons saved in the mouse to send something else (by Synapse, say), which the
/// remapper can't see as buttons, and a reset that puts them back (`SideButtonReset`).
private struct SideButtonResetNotice: View {
    @ObservedObject var controller: MouseController

    var body: some View {
        if controller.checksSideButtons && controller.remappedSideButtons.isEmpty,
           let done = controller.sideButtonResetDone {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text(done).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if controller.checksSideButtons && !controller.remappedSideButtons.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.batteryMid)
                    Text(SideButtonReset.noticeText(controller.remappedSideButtons))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Button(controller.isResettingSideButtons ? "Resetting…" : "Reset Side Buttons") {
                        controller.resetSideButtons()
                    }
                    .disabled(controller.isResettingSideButtons)
                    if let error = controller.sideButtonResetError {
                        Text(error).font(.system(size: 10)).foregroundStyle(Color.batteryMid)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: 11))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.batteryMid.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// The DPI button, on a mouse that can rebind it over Bluetooth. The same menu as every other
/// button, with the mouse's own functions added: what the mouse can do itself is written to it
/// (DPI Cycle, its mouse buttons, keys it can type), and anything else is MacRazer's to carry
/// out, through F20 on the Basilisk V3 X or, on a mouse with private keys, through driver mode
/// (`ButtonRemapper.dpiButtonAssignment`). The menu waits for a read of the mouse that parses,
/// and every write reads the button again first. On the Basilisk the choices are the ones its
/// F20 bridge has always offered: no Gesture… and no Launchpad.
private struct DpiCycleBindingSection: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    var onRecordShortcut: () -> Void
    /// Opens the gesture editor on the DPI button.
    var onGesture: () -> Void

    /// The mouse's functions offered under Mouse besides Middle Click, which every menu has.
    private static let firmwareMouseBindings = BLEProtocol.DPIButtonBinding.allCases.filter {
        $0.buttonID != nil && $0 != .middleClick
    }

    private var menuLabel: String {
        controller.dpiCycleButtonBinding.map { remapper.dpiCycleLabel(for: $0) }
            ?? (controller.isUpdatingDpiCycleButton ? "Reading…" : "Read from mouse…")
    }

    var body: some View {
        if controller.deviceIsBluetooth,
           controller.deviceID.map(RazerDevices.supportsDpiButtonBinding(pid:)) == true {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(ButtonRemapper.label(for: ButtonRemapper.dpiButton)).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 6)
                    // None is DPI Cycle (default), which writes the button's factory function back.
                    RemapActionMenu(label: menuLabel, noneTitle: BLEProtocol.DPIButtonBinding.dpiCycle.label,
                                    onPick: { remapper.configureDpiButton($0, controller: controller) },
                                    onRecord: onRecordShortcut,
                                    onGesture: remapper.supportsDpiPrivateKeys ? {
                                        if remapper.makeDpiGesture(controller: controller) { onGesture() }
                                    } : nil,
                                    extraMouseChoices: Self.firmwareMouseBindings.map { binding in
                                        RemapMenuChoice(title: binding.label) {
                                            remapper.configureDpiCycle(binding, controller: controller)
                                        }
                                    },
                                    softwareChoicesDisabled: !remapper.remappingPermissionsGranted,
                                    offersLaunchpad: remapper.supportsDpiPrivateKeys,
                                    width: 190)
                    .disabled(controller.isUpdatingDpiCycleButton || controller.dpiCycleButtonBinding == nil)
                }
                Text(RemapView.dpiButtonHelpText(privateKeys: remapper.supportsDpiPrivateKeys))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if remapper.dpiCycleSoftwareAction != nil {
                    HStack {
                        Text(remapper.dpiActionStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if remapper.dpiActionNeedsInputMonitoring {
                            Button("Input Monitoring") {
                                // Asked first, so MacRazer is in the list the pane opens on.
                                ButtonRemapper.askForInputMonitoring()
                                SystemSettingsPanes.openInputMonitoring()
                            }
                                .font(.system(size: 10))
                        }
                    }
                    // Input Monitoring turned on while MacRazer runs takes effect only in a new
                    // run (`DpiDriverModeNeed.needsReopen`). The reopen quits as Quit does, so
                    // the DPI button's driver mode is put back first.
                    if remapper.dpiActionNeedsReopen {
                        HStack(spacing: 8) {
                            Button("Reopen MacRazer") { remapper.reopenApp() }
                                .font(.system(size: 10))
                            if remapper.reopenFailed {
                                Text(ButtonRemapper.reopenFailedText).font(.system(size: 10))
                                    .foregroundStyle(Color.batteryMid)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if let error = controller.dpiCycleButtonError {
                    HStack(spacing: 8) {
                        Text(error).font(.system(size: 10)).foregroundStyle(Color.batteryMid)
                        Button("Retry") { controller.refreshDpiCycleButtonBinding() }.font(.system(size: 10))
                    }
                } else if controller.dpiCycleButtonBinding == nil {
                    Button("Read button assignment") { controller.refreshDpiCycleButtonBinding() }
                        .font(.system(size: 10))
                        .disabled(controller.isUpdatingDpiCycleButton)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            // A read only: nothing is written until a choice is made in the menu.
            .onAppear { controller.refreshDpiCycleButtonBinding() }
        }
    }
}

/// Captures a single raw key combination (virtual keyCode + modifiers) for the recorder.
struct KeyRecorderView: NSViewRepresentable {
    var onCapture: (UInt16, CGEventFlags, String) -> Void
    var onCancel: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let v = RecorderNSView()
        v.onCapture = onCapture
        v.onCancel = onCancel
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
    }
}

final class RecorderNSView: NSView {
    var onCapture: ((UInt16, CGEventFlags, String) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) { capture(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { capture(event); return true }

    static func storedFlags(_ modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        if modifiers.contains(.numericPad) { flags.insert(.maskNumericPad) }
        return flags
    }

    private func capture(_ event: NSEvent) {
        let flags = Self.storedFlags(event.modifierFlags)
        // A bare Escape is the universal "get me out" key — cancel the recording rather
        // than binding the mouse button to ⎋. (⌘⎋ etc. still record normally.)
        if event.keyCode == 53, flags.isEmpty {
            onCancel?()
            return
        }
        onCapture?(event.keyCode, flags, Self.display(event))
    }

    private static func display(_ event: NSEvent) -> String {
        var s = ""
        if event.modifierFlags.contains(.control) { s += "⌃" }
        if event.modifierFlags.contains(.option) { s += "⌥" }
        if event.modifierFlags.contains(.shift) { s += "⇧" }
        if event.modifierFlags.contains(.command) { s += "⌘" }
        s += keyName(event)
        return s
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        case 36: return "↩"; case 48: return "⇥"; case 49: return "Space"; case 53: return "⎋"
        case 51: return "⌫"; case 117: return "⌦"
        default:
            let c = (event.charactersIgnoringModifiers ?? "").uppercased()
            return c.isEmpty ? "Key\(event.keyCode)" : c
        }
    }
}

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
    @State private var recordingButton: Int?
    /// Set while recording a Turbo Keybind: its repeat interval.
    @State private var recordingTurboMs: Int?
    /// The mapping slot a custom DPI Clutch is being typed for, and the text typed.
    @State private var clutchButton: Int?
    @State private var clutchText = ""
    @State private var recordingDpiCycleShortcut = false
    @State private var recorderError: String?
    /// Editing the HyperShift layer: each row then sets what its button does while the
    /// HyperShift key is held (`ButtonRemapper.hyperShiftKey`).
    @State private var editingHyperShift = false

    private var buttons: [Int] {
        // A mouse that keeps its remaps lists all its controls, pressed yet or not, in the
        // order they sit on the mouse (`OnboardButtons.rowOrder`).
        let onboard = remapper.onboardControls
        let order = remapper.activeRowOrder
        func rank(_ id: Int) -> Int {
            if let index = order.firstIndex(of: id) { return index }
            return id < 2 ? -1 : order.count // left and right click above the rest
        }
        return Array(remapper.seenButtons.union(remapper.suggestedButtons).union(remapper.mappings.keys).union(onboard))
            .filter { !ButtonRemapper.isHyperShiftKey($0) }
            .filter { HardwareButton(rawValue: $0) == nil || onboard.contains($0) }
            .sorted { (rank($0), $0) < (rank($1), $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if remapper.needsEventTap && !remapper.remappingPermissionsGranted {
                accessibilityBanner
                buttonList
            } else {
                if remapper.remappingPaused && remapper.needsEventTap { pausedNote }
                // A mouse whose table is known lists and names every control already. Others
                // only get a row once a press of it is seen.
                if !remapper.mappingsLiveInMouse { detectionHint }
                buttonList
            }
            if let error = controller?.onboardWriteError, remapper.mappingsLiveInMouse {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.batteryMid)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let controller {
                DpiCycleBindingSection(controller: controller, remapper: remapper) {
                    recorderError = nil
                    recordingDpiCycleShortcut = true
                }
            }
            if let controller { MouseSwitchesSection(controller: controller) }
            if remapper.isBasiliskV3XHyperSpeed { basiliskButtonLimits }
            footer
        }
        // 22 in its own window, like Settings and the other 440-wide windows; 18 inside the
        // popover, like Profiles.
        .padding(onBack == nil ? 22 : 18)
        .frame(width: onBack == nil ? 440 : 320)
        .onAppear { remapper.refreshAccessibility(prompt: false) }
        .overlay { if recordingButton != nil || recordingDpiCycleShortcut { recorderOverlay } }
        .overlay { if clutchButton != nil { clutchOverlay } }
    }

    /// The typed DPI, when it is one the mouse takes.
    private var clutchDPI: Int? {
        Int(clutchText.trimmingCharacters(in: .whitespaces)).flatMap { (100...remapper.activeMaxDPI).contains($0) ? $0 : nil }
    }

    private var clutchOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture { clutchButton = nil }
            VStack(spacing: 14) {
                Text("DPI while held").font(.system(size: 14, weight: .semibold))
                Text("for \(clutchButton.map { remapper.displayLabel(for: $0) } ?? "")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("100 – \(remapper.activeMaxDPI)", text: $clutchText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .onSubmit(saveClutch)
                if !clutchText.isEmpty && clutchDPI == nil {
                    Text("Enter a DPI from 100 to \(remapper.activeMaxDPI).")
                        .font(.system(size: 10)).foregroundStyle(Color.batteryMid)
                }
                HStack {
                    Button("Cancel") { clutchButton = nil }
                    Button("Set", action: saveClutch)
                        .keyboardShortcut(.defaultAction)
                        .disabled(clutchDPI == nil)
                }
            }
            .padding(20)
            .frame(width: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func saveClutch() {
        guard let button = clutchButton, let dpi = clutchDPI else { return }
        remapper.setAction(.dpiClutch(dpi: dpi), for: button)
        clutchButton = nil
    }

    private var recorderOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture {
                recordingButton = nil
                recordingTurboMs = nil
                recordingDpiCycleShortcut = false
                recorderError = nil
            }
            VStack(spacing: 14) {
                Text("Press a key or combination").font(.system(size: 14, weight: .semibold))
                Text("for \(recordingDpiCycleShortcut ? "DPI Cycle" : recordingButton.map { remapper.displayLabel(for: $0) } ?? "")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                KeyRecorderView(onCapture: { keyCode, flags, display in
                    if let b = recordingButton {
                        if let ms = recordingTurboMs {
                            remapper.setAction(.turboKey(keyCode: keyCode, modifiers: flags.rawValue, name: display, intervalMs: ms), for: b)
                        } else {
                            remapper.setAction(.keystroke(keyCode: keyCode, modifiers: flags.rawValue, name: display), for: b)
                        }
                        recordingTurboMs = nil
                    }
                    if recordingDpiCycleShortcut {
                        if let binding = dpiShortcutBinding(keyCode: keyCode, flags: flags), let controller {
                            remapper.configureDpiCycle(binding, controller: controller)
                            recordingDpiCycleShortcut = false
                            recorderError = nil
                        } else {
                            recorderError = "This key is not supported by the mouse's Bluetooth shortcut format."
                        }
                    } else {
                        recordingButton = nil
                    }
                }, onCancel: {
                    recordingButton = nil
                    recordingTurboMs = nil
                    recordingDpiCycleShortcut = false
                    recorderError = nil
                })
                .frame(height: 46)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.razerGreen, lineWidth: 1.5))
                if let recorderError {
                    Text(recorderError).font(.system(size: 10)).foregroundStyle(Color.batteryMid)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Cancel") {
                    recordingButton = nil
                    recordingTurboMs = nil
                    recordingDpiCycleShortcut = false
                    recorderError = nil
                }
            }
            .padding(20)
            .frame(width: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func dpiShortcutBinding(keyCode: UInt16, flags: CGEventFlags) -> BLEProtocol.DPIButtonBinding? {
        guard let usage = BLEProtocol.hidUsage(forMacKeyCode: keyCode) else { return nil }
        return .keyboardShortcut(hidUsage: usage, modifiers: DPIShortcutModifiers.hidValue(from: flags))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Esc belongs to the key recorder while it's up: it cancels the recording.
            if let onBack {
                BackButton(action: onBack, escapes: recordingButton == nil && !recordingDpiCycleShortcut)
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
                Text("Detected: \(remapper.displayLabel(for: b))")
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

    /// Standard / HyperShift, once a button is the HyperShift key.
    @ViewBuilder private var layerPicker: some View {
        if remapper.hasHyperShiftKey {
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: $editingHyperShift) {
                    Text("Standard").tag(false)
                    Text("HyperShift").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if editingHyperShift {
                    Text(remapper.mappingsLiveInMouse
                         ? "What each button does while you hold the Side Trigger, saved in the mouse. Buttons left at Default do their standard job."
                         : "What each button does while you hold the HyperShift button. Buttons left at Default do their standard job.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The mapping key a row edits: the button itself, or its HyperShift slot.
    private func key(for button: Int) -> Int {
        editingHyperShift && remapper.hasHyperShiftKey ? ButtonRemapper.hyperShiftKey(button) : button
    }

    @ViewBuilder private var buttonList: some View {
        layerPicker
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
        let slot = key(for: button)
        let isShiftKey = remapper.isHyperShiftClutch(button)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(remapper.displayLabel(for: button))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if remapper.remapCantFire(button) {
                    Text("The mouse can't do this one itself")
                        .font(.system(size: 9)).foregroundStyle(Color.batteryMid)
                }
            }
            Spacer(minLength: 6)
            if isShiftKey && slot != button {
                Text("HyperShift").foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .trailing)
            } else {
                actionMenu(for: slot, allowsHyperShift: slot == button)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The action picker for one mapping slot, laid out like Synapse's: Keyboard, Mouse,
    /// Sensitivity, Multimedia, then the mouse's own jobs and Disable. `allowsHyperShift`
    /// offers making the button the HyperShift key, on the standard layer only. Anything the
    /// control already does from the factory is greyed out: its Default item is that.
    private func actionMenu(for button: Int, allowsHyperShift: Bool) -> some View {
        let control = ButtonRemapper.isHyperShiftKey(button) ? button - ButtonRemapper.hyperShiftOffset : button
        // A mouse that keeps its remaps does all of these itself, on any control and either
        // layer. Elsewhere MacRazer does Double Click, on a control whose presses it sees.
        let inMouse = remapper.mappingsLiveInMouse
        let offersDoubleClick = inMouse || remapper.appSees(control)
        // Scroll Up and Down are wheel steps: Synapse gives them keys, mouse actions,
        // multimedia and Disable, and nothing held or repeated.
        let wheelStep = control == HardwareButton.scrollUp.rawValue || control == HardwareButton.scrollDown.rawValue
        func item(_ title: String, _ action: RemapAction) -> some View {
            Button(title) { remapper.setAction(action, for: button) }
                .disabled(remapper.isDefault(action, for: control))
        }
        return Menu {
            Button("Default (\(remapper.defaultLabel(for: button)))") { remapper.setAction(.passthrough, for: button) }
            Menu("Keyboard") {
                Button("Record Keybind…") { recordingButton = button }
                if inMouse && !wheelStep {
                    Menu("Record Turbo Keybind") {
                        ForEach(RemapAction.turboRates, id: \.self) { rate in
                            Button("\(rate) per second…") {
                                recordingTurboMs = RemapAction.intervalMs(perSecond: rate)
                                recordingButton = button
                            }
                        }
                    }
                }
            }
            Menu("Mouse") {
                ForEach(Array(["Left Click", "Right Click", "Middle Click", "Back", "Forward"].enumerated()), id: \.offset) { hid, name in
                    let title = ["Left Click", "Right Click", "Scroll Click", "Mouse Button 4 (Back)", "Mouse Button 5 (Forward)"][hid]
                    item(title, .mouseButton(button: hid, name: name))
                }
                if offersDoubleClick { item("Double Click", .doubleClick) }
                if inMouse {
                    Divider()
                    ForEach(ScrollDirection.allCases, id: \.self) { direction in
                        // Sideways the mouse only has the repeating scroll (`scrollBlock`).
                        item(direction.label, .scroll(direction: direction, repeating: !direction.isVertical))
                    }
                    if !wheelStep {
                        item("Repeat Scroll Up", .scroll(direction: .up, repeating: true))
                        item("Repeat Scroll Down", .scroll(direction: .down, repeating: true))
                        Divider()
                        ForEach([(0, "Left Click"), (1, "Right Click")], id: \.0) { hid, name in
                            Menu("Turbo \(name)") {
                                ForEach(RemapAction.turboRates, id: \.self) { rate in
                                    Button("\(rate) per second") {
                                        remapper.setAction(.turboClick(button: hid, intervalMs: RemapAction.intervalMs(perSecond: rate), name: name), for: button)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if inMouse && !wheelStep {
                Menu("Sensitivity") {
                    item("Stage Up", .dpiStage(up: true))
                    item("Stage Down", .dpiStage(up: false))
                    Menu("Clutch") {
                        ForEach(RemapAction.clutchDPIs, id: \.self) { dpi in
                            Button("\(dpi) DPI while held") { remapper.setAction(.dpiClutch(dpi: dpi), for: button) }
                        }
                        Divider()
                        Button("Custom DPI…") {
                            clutchText = ""
                            clutchButton = button
                        }
                    }
                }
            }
            Menu("Multimedia") {
                ForEach(ButtonRemapper.mediaOptions, id: \.code) { opt in
                    Button(opt.name) { remapper.setAction(.mediaKey(code: opt.code, name: opt.name), for: button) }
                }
            }
            if inMouse && !wheelStep {
                if controller?.supportsOnboardSlots == true {
                    Menu("Profile") {
                        item("Cycle Up Profile", .cycleProfile(up: true))
                        item("Cycle Down Profile", .cycleProfile(up: false))
                    }
                }
                item("Cycle Scroll Mode", .cycleScrollMode)
                // A mouse that keeps its remaps does HyperShift itself, on any control. Other
                // mice aren't offered it.
                if allowsHyperShift { item("HyperShift", .hyperShift) }
            }
            Divider()
            item("Disable", .disabled)
        } label: {
            // Remapped rows in the accent green, defaults muted, so changes stand out. A plain
            // label: the borderless menu style draws its title in its own colour.
            let remapped = remapper.isRemapped(button)
            HStack(spacing: 4) {
                Text(remapper.actionLabel(for: button))
                    .fontWeight(remapped ? .medium : .regular)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(remapped ? Color.razerGreenText : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 150)
    }

    @ViewBuilder private var footer: some View {
        if remapper.mappingsLiveInMouse {
            Text("Remaps are saved in the mouse, both layers: they keep working with MacRazer "
                 + "closed, over Bluetooth, the dongle or the cable, and on other computers. Hold the "
                 + "Side Trigger, or any button set to HyperShift, for the HyperShift layer.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            appFooter
        }
    }

    private var appFooter: some View {
        Text("Remapping works while this app is running and the mouse is connected; it "
             + "pauses when the mouse goes offline. macOS can't tell which mouse sent a "
             + "click, so while connected the mappings apply to matching buttons on any "
             + "pointing device. Mappings are saved automatically.")
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var basiliskButtonLimits: some View {
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

/// The mouse's own switches, grouped in one box like the button list, each once the mouse has
/// reported it: Smart-Reel on the wheels MacRazer knows (`RazerDevices.hasWheelControls`) and
/// its sensitivity (`RazerDevices.hasSmartReelSensitivity`), and scroll acceleration with its
/// level (`RazerDevices.hasScrollAcceleration`). A level shows while its switch is on.
private struct MouseSwitchesSection: View {
    @ObservedObject var controller: MouseController

    var body: some View {
        let reel = controller.smartReel
        let acceleration = controller.scrollAcceleration
        if reel != nil || acceleration != nil {
            VStack(spacing: 0) {
                if let on = reel {
                    switchRow("Smart-Reel", isOn: Binding(get: { on }, set: { controller.setSmartReel($0) }),
                              detail: "A fast flick of the wheel spins it freely, then it clicks again as it slows down. Saved on the mouse.")
                    if on, let level = controller.smartReelSensitivity {
                        divider
                        levelRow("Sensitivity", level: level, set: controller.setSmartReelSensitivity,
                                 detail: "How lightly a flick sets the wheel spinning freely. High lets go almost at once. Saved on the mouse.")
                    }
                }
                if let on = acceleration {
                    if reel != nil { divider }
                    switchRow("Scroll Acceleration", isOn: Binding(get: { on }, set: { controller.setScrollAcceleration($0) }),
                              detail: "In free spin, the faster the wheel turns, the further it scrolls. Saved on the mouse.")
                    if on, let level = controller.scrollAccelerationLevel {
                        divider
                        levelRow("Acceleration", level: level, set: controller.setScrollAccelerationLevel,
                                 detail: "How much a fast free spin speeds scrolling up. Saved on the mouse.")
                    }
                }
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var divider: some View { Divider().overlay(Color.primary.opacity(0.1)) }

    /// A slider over the mouse's levels (`RazerCommands.wheelLevelRange`), Low / Medium / High
    /// marked at its ends and middle as in Synapse.
    private func levelRow(_ title: String, level: Int, set: @escaping (Int) -> Void, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium))
            LevelSlider(title: title, level: level, set: set)
            Text(detail)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>, detail: String, error: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) {
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .tint(.razerGreen)
            .controlSize(.small)
            Text(detail)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(Color.batteryMid)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A stepped slider for a mouse level, sending the level once the drag ends. The labels sit under
/// the first, middle and last stops; the one the level is on reads bolder.
private struct LevelSlider: View {
    let title: String
    let level: Int
    let set: (Int) -> Void
    @State private var value: Double

    private static let range = RazerCommands.wheelLevelRange
    private static let marks: [(name: String, level: Int)] = [
        ("Low", range.lowerBound),
        ("Medium", (range.lowerBound + range.upperBound) / 2),
        ("High", range.upperBound),
    ]

    init(title: String, level: Int, set: @escaping (Int) -> Void) {
        self.title = title
        self.level = level
        self.set = set
        _value = State(initialValue: Double(level))
    }

    var body: some View {
        VStack(spacing: 2) {
            Slider(value: $value, in: Double(Self.range.lowerBound)...Double(Self.range.upperBound), step: 1) { editing in
                if !editing, Int(value) != level { set(Int(value)) }
            }
            .tint(.razerGreen)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(title)
            .accessibilityValue(Self.marks.first { $0.level == Int(value) }?.name ?? "\(Int(value))")
            HStack(spacing: 0) {
                ForEach(Self.marks, id: \.level) { mark in
                    Text(mark.name)
                        .font(.system(size: 9.5, weight: Int(value) == mark.level ? .semibold : .regular))
                        .foregroundStyle(Int(value) == mark.level ? Color.razerGreenText : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: mark.level == Self.range.lowerBound ? .leading
                               : mark.level == Self.range.upperBound ? .trailing : .center)
                }
            }
            .accessibilityHidden(true)
        }
        .onChange(of: level) { _, new in value = Double(new) }
    }
}

private struct DpiCycleBindingSection: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    var onRecordShortcut: () -> Void

    var body: some View {
        if controller.deviceIsBluetooth,
           controller.deviceID.map(RazerDevices.supportsDpiButtonBinding(pid:)) == true {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("DPI Cycle").font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 6)
                    Menu {
                        Button("DPI Cycle (default)") {
                            remapper.configureDpiCycle(.dpiCycle, controller: controller)
                        }
                        Menu("Shortcut") {
                            ForEach(ButtonRemapper.presets) { preset in
                                if let binding = dpiShortcutBinding(for: preset) {
                                    Button(preset.name) { remapper.configureDpiCycle(binding, controller: controller) }
                                }
                            }
                        }
                        Menu("Mouse") {
                            ForEach(BLEProtocol.DPIButtonBinding.allCases.filter { $0.buttonID != nil }) { binding in
                                Button(binding.label) { remapper.configureDpiCycle(binding, controller: controller) }
                            }
                            Button("Double Click") {
                                remapper.configureDpiCycle(.softwareBridge, softwareAction: .doubleClick, controller: controller)
                            }
                            .disabled(!remapper.remappingPermissionsGranted)
                        }
                        Menu("Media") {
                            ForEach(ButtonRemapper.mediaOptions, id: \.code) { option in
                                Button(option.name) {
                                    remapper.configureDpiCycle(.softwareBridge,
                                        softwareAction: .mediaKey(code: option.code, name: option.name), controller: controller)
                                }
                            }
                        }
                        .disabled(!remapper.remappingPermissionsGranted)
                        Divider()
                        Button("Record Keybind…", action: onRecordShortcut)
                    } label: {
                        Text(controller.dpiCycleButtonBinding.map { remapper.dpiCycleLabel(for: $0) }
                             ?? (controller.isUpdatingDpiCycleButton ? "Reading…" : "Read from mouse…"))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 190)
                    .disabled(controller.isUpdatingDpiCycleButton || controller.dpiCycleButtonBinding == nil)
                }
                Text("Media and Double Click require MacRazer running with Accessibility and Input Monitoring enabled. They reserve F20 while active; select DPI Cycle (default) to restore the original button.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if remapper.dpiCycleSoftwareAction != nil {
                    HStack {
                        Text(remapper.dpiBridgeStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        if !remapper.keyboardCaptureAvailable {
                            Button("Input Monitoring") { SystemSettingsPanes.openInputMonitoring() }
                                .font(.system(size: 10))
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
            .onAppear { controller.refreshDpiCycleButtonBinding() }
        }
    }

    private func dpiShortcutBinding(for preset: RemapPreset) -> BLEProtocol.DPIButtonBinding? {
        guard let usage = BLEProtocol.hidUsage(forMacKeyCode: preset.keyCode) else { return nil }
        return .keyboardShortcut(hidUsage: usage, modifiers: DPIShortcutModifiers.hidValue(from: preset.flags))
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

    /// A modifier pressed with nothing else held: recorded as the lone key when it is released
    /// before any other key goes down (a combination records on its key's press instead).
    private var pendingModifier: UInt16?

    override func keyDown(with event: NSEvent) { pendingModifier = nil; capture(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        pendingModifier = nil
        capture(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard let flag = Self.modifierKeys[event.keyCode]?.flag else { return }
        let held = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if held.contains(flag) {
            // Pressed: a candidate only when it is the one modifier held.
            pendingModifier = held == flag ? event.keyCode : nil
        } else if pendingModifier == event.keyCode {
            pendingModifier = nil
            onCapture?(event.keyCode, [], Self.modifierKeys[event.keyCode]!.name)
        }
    }

    /// The Mac's virtual key codes for the modifier keys, left and right apart.
    static let modifierKeys: [UInt16: (flag: NSEvent.ModifierFlags, name: String)] = [
        59: (.control, "Left ⌃"), 62: (.control, "Right ⌃"),
        56: (.shift, "Left ⇧"), 60: (.shift, "Right ⇧"),
        58: (.option, "Left ⌥"), 61: (.option, "Right ⌥"),
        55: (.command, "Left ⌘"), 54: (.command, "Right ⌘"),
    ]

    private func capture(_ event: NSEvent) {
        var flags = CGEventFlags()
        if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
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

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

struct RemapView: View {
    @ObservedObject var remapper: ButtonRemapper
    var controller: MouseController?
    var onBack: (() -> Void)?
    var checkAccessibilityOnAppear = true
    @State private var recordingButton: Int?
    @State private var recordingDpiCycleShortcut = false
    @State private var recorderError: String?

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MacRazer"
    }

    private var accessibilitySettingsName: String {
        if #available(macOS 27, *) { return "Device Control and Data Access" }
        return "Accessibility"
    }

    private var openAccessibilitySettingsTitle: String {
        if #available(macOS 27, *) { return "Open Device Control Settings" }
        return "Open Accessibility Settings"
    }

    private var buttons: [Int] {
        Array(remapper.seenButtons.union(remapper.suggestedButtons).union(remapper.mappings.keys)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !remapper.remappingPermissionsGranted {
                accessibilityBanner
                buttonList
            } else {
                if remapper.remappingPaused { pausedNote }
                detectionHint
                buttonList
            }
            if let controller {
                DpiCycleBindingSection(controller: controller, remapper: remapper) {
                    recorderError = nil
                    recordingDpiCycleShortcut = true
                }
            }
            if remapper.isBasiliskV3XHyperSpeed { basiliskButtonLimits }
            footer
        }
        .padding(18)
        .frame(width: onBack == nil ? 440 : 320)
        .onAppear {
            if checkAccessibilityOnAppear { remapper.refreshAccessibility(prompt: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if checkAccessibilityOnAppear { remapper.refreshAccessibility(prompt: false) }
        }
        .overlay { if recordingButton != nil || recordingDpiCycleShortcut { recorderOverlay } }
    }

    private var recorderOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture {
                recordingButton = nil
                recordingDpiCycleShortcut = false
                recorderError = nil
            }
            VStack(spacing: 14) {
                Text("Press a key combination").font(.system(size: 14, weight: .semibold))
                Text("for \(recordingDpiCycleShortcut ? "DPI Cycle" : recordingButton.map { ButtonRemapper.label(for: $0) } ?? "")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                KeyRecorderView(onCapture: { keyCode, flags, display in
                    if let b = recordingButton {
                        remapper.setAction(.keystroke(keyCode: keyCode, modifiers: flags.rawValue, name: display), for: b)
                    }
                    if recordingDpiCycleShortcut {
                        if let binding = dpiShortcutBinding(keyCode: keyCode, flags: flags) {
                            if let controller { remapper.configureDpiCycle(binding, controller: controller) }
                            recordingDpiCycleShortcut = false
                            recorderError = nil
                        } else {
                            recorderError = "This key is not supported by the mouse’s Bluetooth shortcut format. Try a letter, number, arrow, or common key."
                        }
                    } else {
                        recordingButton = nil
                    }
                }, onCancel: {
                    recordingButton = nil
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
                    recordingDpiCycleShortcut = false
                    recorderError = nil
                }
            }
            .padding(20)
            .frame(width: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func dpiShortcutBinding(keyCode: UInt16, flags: CGEventFlags) -> BLEVendorProtocol.DPIButtonBinding? {
        guard let usage = BLEVendorProtocol.hidUsage(forMacKeyCode: keyCode) else { return nil }
        var modifiers: UInt8 = 0
        if flags.contains(.maskControl) { modifiers |= 0x01 }
        if flags.contains(.maskShift) { modifiers |= 0x02 }
        if flags.contains(.maskAlternate) { modifiers |= 0x04 }
        if flags.contains(.maskCommand) { modifiers |= 0x08 }
        return .keyboardShortcut(hidUsage: usage, modifiers: modifiers)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let onBack { BackButton(action: onBack) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Configure Buttons").font(.system(size: 16, weight: .semibold))
                Text("Remap extra buttons in macOS while MacRazer is running.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(permissionProblemTitle, systemImage: "lock.shield")
                .font(.system(size: 13, weight: .medium))
            Text(permissionProblemDescription)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Bundle.main.bundleURL.path)
                .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(openAccessibilitySettingsTitle) { remapper.openAccessibilitySettings() }
                Button("Request / Re-check") { remapper.refreshAccessibility(prompt: true) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var permissionProblemTitle: String {
        if !remapper.accessibilityGranted { return "Accessibility permission required" }
        return "macOS did not create the button event tap"
    }

    private var permissionProblemDescription: String {
        let nextStep: String
        if !remapper.accessibilityGranted {
            nextStep = "Enable “\(appDisplayName)” in System Settings → Privacy & Security → \(accessibilitySettingsName), then select “Request / Re-check”."
        } else {
            nextStep = "Accessibility is enabled, but macOS refused the global button event tap. Reopen Device Control and Data Access, confirm “\(appDisplayName)” is enabled, then select “Request / Re-check”."
        }
        let identityHint = AppCodeIdentity.isAdHoc
            ? " This build has a temporary code identity that changes when rebuilt. Use a certificate-signed build to keep grants across updates."
            : " If this copy is already enabled, remove and re-add this exact app in System Settings, then reopen it."
        return "MacRazer needs Accessibility to capture extra mouse buttons. You can save mappings below. " + nextStep + identityHint
    }

    private var basiliskButtonLimits: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Color.batteryMid)
            Text("The Multi-function/Hypershift trigger stays an onboard modifier. This firmware does not expose it for Bluetooth remapping, so MacRazer cannot assign it directly. DPI Cycle can be configured below through the mouse’s Bluetooth control channel.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.batteryMid.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
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
            Image(systemName: "cursorarrow.click.2").foregroundStyle(Color.razerGreen)
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
            Menu {
                Button("None (default)") { remapper.setAction(.passthrough, for: button) }
                Menu("Shortcut") {
                    ForEach(ButtonRemapper.presets) { p in
                        Button(p.name) { remapper.setAction(p.action, for: button) }
                    }
                }
                Menu("Mouse") {
                    Button("Middle Click") { remapper.setAction(.mouseButton(button: 2, name: "Middle Click"), for: button) }
                    Button("Double Click") { remapper.setAction(.doubleClick, for: button) }
                }
                Menu("Media") {
                    ForEach(ButtonRemapper.mediaOptions, id: \.code) { opt in
                        Button(opt.name) { remapper.setAction(.mediaKey(code: opt.code, name: opt.name), for: button) }
                    }
                }
                Divider()
                Button("Record Custom Shortcut…") { recordingButton = button }
            } label: {
                Text(remapper.actionLabel(for: button))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 150)
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
}

private struct DpiCycleBindingSection: View {
    @ObservedObject var controller: MouseController
    @ObservedObject var remapper: ButtonRemapper
    var onRecordShortcut: () -> Void

    var body: some View {
        if controller.deviceID == 0x00BA, controller.deviceIsBluetooth {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("DPI Cycle")
                        .font(.system(size: 12, weight: .medium))
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
                            ForEach(BLEVendorProtocol.DPIButtonBinding.allCases.filter { $0.buttonID != nil }) { binding in
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
                        Button("Record Custom Shortcut…", action: onRecordShortcut)
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
                        Text(remapper.dpiBridgeStatus)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
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
                        Button("Retry") { controller.refreshDpiCycleButtonBinding() }
                            .font(.system(size: 10))
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
            .onChange(of: controller.deviceKey) { oldKey, newKey in
                if oldKey != nil, oldKey != newKey { controller.refreshDpiCycleButtonBinding() }
            }
        }
    }

    private func dpiShortcutBinding(for preset: RemapPreset) -> BLEVendorProtocol.DPIButtonBinding? {
        guard let usage = BLEVendorProtocol.hidUsage(forMacKeyCode: preset.keyCode) else { return nil }
        var modifiers: UInt8 = 0
        if preset.flags.contains(.maskControl) { modifiers |= 0x01 }
        if preset.flags.contains(.maskShift) { modifiers |= 0x02 }
        if preset.flags.contains(.maskAlternate) { modifiers |= 0x04 }
        if preset.flags.contains(.maskCommand) { modifiers |= 0x08 }
        return .keyboardShortcut(hidUsage: usage, modifiers: modifiers)
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

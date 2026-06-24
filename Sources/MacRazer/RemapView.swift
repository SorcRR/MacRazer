// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

struct RemapView: View {
    @ObservedObject var remapper: ButtonRemapper
    var onBack: (() -> Void)?
    @State private var recordingButton: Int?

    private var buttons: [Int] {
        Array(remapper.seenButtons.union(remapper.mappings.keys)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !remapper.accessibilityGranted {
                accessibilityBanner
            } else {
                detectionHint
                buttonList
            }
            footer
        }
        .padding(18)
        .frame(width: onBack == nil ? 440 : 320)
        .onAppear { remapper.refreshAccessibility(prompt: false) }
        .overlay { if recordingButton != nil { recorderOverlay } }
    }

    private var recorderOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture { recordingButton = nil }
            VStack(spacing: 14) {
                Text("Press a key combination").font(.system(size: 14, weight: .semibold))
                Text("for \(recordingButton.map { ButtonRemapper.label(for: $0) } ?? "")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                KeyRecorderView { keyCode, flags, display in
                    if let b = recordingButton {
                        remapper.setAction(.keystroke(keyCode: keyCode, modifiers: flags.rawValue, name: display), for: b)
                    }
                    recordingButton = nil
                }
                .frame(height: 46)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.razerGreen, lineWidth: 1.5))
                Button("Cancel") { recordingButton = nil }
            }
            .padding(20)
            .frame(width: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let onBack { BackButton(action: onBack) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Configure Buttons").font(.system(size: 16, weight: .semibold))
                Text("Remap your mouse's extra buttons.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Accessibility permission required", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .medium))
            Text("Button remapping intercepts mouse events, which needs Accessibility access. "
                 + "Enable “MacRazer” in System Settings, then relaunch the app.")
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
        Text("Remapping works while this app is running. Mappings are saved automatically.")
            .font(.system(size: 10)).foregroundStyle(.tertiary)
    }
}

/// Captures a single raw key combination (virtual keyCode + modifiers) for the recorder.
struct KeyRecorderView: NSViewRepresentable {
    var onCapture: (UInt16, CGEventFlags, String) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = RecorderNSView()
        v.onCapture = onCapture
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
    }
}

final class RecorderNSView: NSView {
    var onCapture: ((UInt16, CGEventFlags, String) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) { capture(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { capture(event); return true }

    private func capture(_ event: NSEvent) {
        var flags = CGEventFlags()
        if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
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

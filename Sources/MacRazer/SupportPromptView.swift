// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Asks someone whose mouse isn't fully supported to run the device test. Opened by the app
/// when such a mouse connects; see `SupportPromptPolicy` for how often.
struct SupportPromptView: View {
    let mouse: UnsupportedMouse
    var onRunTest: () -> Void
    var onNotNow: () -> Void
    var onDontAsk: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if mouse.canControl { readyBody } else { needsAccessBody }
            HStack(spacing: 10) {
                Button("Don't ask for this mouse", action: onDontAsk)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Not Now", action: onNotNow)
                    .keyboardShortcut(.cancelAction)
                // Not the default action: the window opens on its own, and Return pressed for
                // something else shouldn't start a test.
                Button(mouse.canControl ? "Run the Test" : "Get Started", action: onRunTest)
                    .buttonStyle(RazerProminentButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(Color.razerGreenBright.opacity(0.20))
                Image(systemName: "computermouse.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.razerGreenBright)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(mouse.canControl ? "Help us support your mouse" : "We found a new Razer mouse")
                    .font(.system(size: 20, weight: .semibold))
                HStack(spacing: 6) {
                    Text(mouse.name).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(connectionLabel)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.razerGreenText)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.razerGreenText.opacity(0.15), in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The popover's chip wording.
    private var connectionLabel: String {
        RazerDevices.connection(pid: mouse.pid)?.label ?? RazerConnection.unknownLabel
    }

    private var readyBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MacRazer doesn't fully support this mouse yet. Some controls may work, others are a best guess.")
                Text("A short test checks what it can do and sends the results to us, so the next release can support it properly.")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                point("clock", "About 2 minutes. You click a few buttons when asked.")
                point("checkmark.shield", "Only mouse details. No personal data, nothing typed.")
                point("eye", "You see the full report before anything is sent.")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var needsAccessBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MacRazer can't control this mouse yet. A short test tells us what it needs, and it starts with one permission.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                step(1, "Allow Input Monitoring", "Needed to talk to the mouse. System Settings opens for you.",
                     current: true)
                step(2, "Run the test", "About 2 minutes. You review the report before sending.", current: false)
            }
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        // A fixed icon column: the symbols differ in width, and Label would let the text shift.
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Color.razerGreenText)
                .frame(width: 16)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func step(_ number: Int, _ title: String, _ detail: String, current: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(current ? Color.onRazerGreen : .secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(current ? Color.razerGreen : Color.clear))
                .overlay(Circle().strokeBorder(current ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(current ? .primary : .secondary)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(current ? 0.05 : 0.03), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Hosts `SupportPromptView`. Opened by the app, never by a click, so it doesn't take focus.
@MainActor
final class SupportPromptWindowController: NSObject, AppWindowPresenter, NSWindowDelegate {
    private let prompt: SupportPrompt
    private let onRunTest: () -> Void
    /// Called a turn after the window closes, once it no longer counts as open.
    private let onClosed: () -> Void
    private var window: NSWindow?

    init(prompt: SupportPrompt, onRunTest: @escaping () -> Void, onClosed: @escaping () -> Void) {
        self.prompt = prompt
        self.onRunTest = onRunTest
        self.onClosed = onClosed
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Brings back a window already built. There is nothing to show before `show(for:)`, which
    /// is how the app opens it.
    func show() { window?.makeKeyAndOrderFront(nil) }

    func show(for mouse: UnsupportedMouse) {
        // Rebuilt each time: the mouse, and with it the whole message, can differ.
        window?.delegate = nil
        window?.close()
        let controller = NSHostingController(rootView: SupportPromptView(
            mouse: mouse,
            onRunTest: { [weak self] in
                self?.window?.close()
                self?.onRunTest()
            },
            onNotNow: { [weak self] in self?.window?.close() },
            onDontAsk: { [weak self] in
                self?.prompt.markDeclined(pid: mouse.pid)
                self?.window?.close()
            }))
        controller.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: controller)
        w.title = "Help Support This Mouse"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        AppearanceSettings.shared.track(w)
        w.delegate = self
        w.center()
        window = w
        prompt.markAsked(pid: mouse.pid)
        w.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        // Deferred like the Updated window's: it still counts as visible during this call.
        DispatchQueue.main.async { [weak self] in self?.onClosed() }
    }
}

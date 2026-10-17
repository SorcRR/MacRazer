// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// The one-time question for a new install: share usage stats or not. Shows this Mac's real
/// values, so the answer is about something concrete. Existing users get the same question as
/// a card in the Updated window instead (`UsageStatsCard`).
struct UsageStatsConsentView: View {
    @ObservedObject var stats: UsageStats
    /// Not optional, for the same reason as `AboutView.onDone`.
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(Color.razerGreenBright.opacity(0.20))
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.razerGreenBright)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Help improve MacRazer?").font(.system(size: 20, weight: .semibold))
                    Text("Share a few basic details so I know which mice to support next.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            titledSection("What this Mac would send") {
                UsageStatsSummary(ping: stats.preview)
                sectionNote("The ID is a scrambled code made from this Mac. It stays the same if you "
                    + "reinstall, so you're counted once. It can't be turned back into your serial number.")
            }
            titledSection("Never sent") {
                sectionNote("Your name, email or IP address. Your files. What you click, type or set up in the app.")
            }
            sectionNote("It's sent once when you install, once after each update, and when you plug in a "
                + "mouse this Mac hasn't reported yet. You can turn it off or delete what's stored any "
                + "time in Settings.")
            HStack(spacing: 10) {
                Link("Privacy details", destination: ProjectLinks.privacy)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.razerGreenText)
                Spacer()
                Button("No Thanks") { stats.setConsent(false); onDone() }
                    .keyboardShortcut(.cancelAction)
                // Not the default action: Return shouldn't be a way to say yes without reading.
                Button("Share") { stats.setConsent(true); onDone() }
                    .buttonStyle(RazerProminentButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

/// The ping in words: one row per thing sent. Shared by the consent window and the card.
struct UsageStatsSummary: View {
    let ping: UsagePing

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            row("Mouse", ping.mice.isEmpty ? "None connected yet" : ping.mice.map(\.name).joined(separator: ", "))
            row("MacRazer", ping.app)
            row("macOS", "\(ping.os), \(ping.arch == "arm64" ? "Apple Silicon" : "Intel")")
            row("ID for this Mac", "\(ping.id.prefix(8))…\(ping.id.suffix(4))", mono: true)
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12.5))
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// The JSON a ping goes as, for "What's sent". The same value the app posts.
struct UsageStatsJSON: View {
    let ping: UsagePing

    var body: some View {
        Text(ping.json(pretty: true))
            .font(.system(size: 10.5, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The question, for someone who already had MacRazer: a card in the Updated window, which
/// they see anyway, rather than a second window on top of it. Stays after an answer to say
/// what happens next.
struct UsageStatsCard: View {
    @ObservedObject var stats: UsageStats
    @State private var answered = false
    @State private var showDetails = false

    var body: some View {
        if stats.consent == .undecided || answered {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.razerGreenBright)
                    Text("Help improve MacRazer?").font(.system(size: 13, weight: .semibold))
                }
                if answered {
                    sectionNote(stats.consent == .granted
                        ? "Thanks! You can turn it off or delete what's stored in Settings › Privacy."
                        : "Okay, nothing will be sent. You can change your mind in Settings › Privacy.")
                } else {
                    sectionNote("Share your mouse model, app version and macOS version, plus a scrambled ID "
                        + "for this Mac so it's only counted once. Nothing personal. You can turn it off in Settings.")
                    if showDetails {
                        UsageStatsSummary(ping: stats.preview)
                    }
                    HStack(spacing: 10) {
                        Button(showDetails ? "Hide details" : "See what's sent") { showDetails.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.razerGreenText)
                        Spacer()
                        Button("No Thanks") { answer(false) }.controlSize(.small)
                        Button("Share") { answer(true) }
                            .controlSize(.small)
                            .buttonStyle(RazerProminentButtonStyle())
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.razerGreen.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.razerGreen.opacity(0.35)))
        }
    }

    private func answer(_ granted: Bool) {
        stats.setConsent(granted)
        answered = true
    }
}

/// Hosts `UsageStatsConsentView` in its own window, opened by the app once, not by a click.
/// Closing it without answering counts as no: the question isn't asked again.
@MainActor
final class UsageStatsWindowController: NSObject, AppWindowPresenter, NSWindowDelegate {
    private let stats: UsageStats
    /// Called a turn after the window closes, once it no longer counts as open.
    private let onClosed: () -> Void
    private var window: NSWindow?

    init(stats: UsageStats, onClosed: @escaping () -> Void) {
        self.stats = stats
        self.onClosed = onClosed
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() { show(activating: true) }

    /// - Parameter activating: whether to take focus. False when the app opens it on its own:
    ///   someone typing elsewhere could otherwise press Esc into it and decline unread. It
    ///   still comes to the front, where it will be seen.
    func show(activating: Bool) {
        if window == nil {
            let controller = NSHostingController(rootView: UsageStatsConsentView(
                stats: stats, onDone: { [weak self] in self?.window?.close() }))
            controller.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: controller)
            w.title = "Help Improve MacRazer"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            AppearanceSettings.shared.track(w)
            w.delegate = self
            w.center()
            window = w
        }
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        stats.dismissUnanswered()
        // Deferred like the Updated window's: it still counts as visible during this call.
        DispatchQueue.main.async { [weak self] in self?.onClosed() }
    }
}

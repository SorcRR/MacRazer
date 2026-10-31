// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Asks someone whose mouse could use a report to run the device test: one that isn't on the
/// verified list, one that is only partly verified, or one verified on this link whose other
/// ways of connecting still need a test. Opened by the app when such a mouse connects; see
/// `SupportPromptPolicy` for how often.
struct SupportPromptView: View {
    let mouse: UnsupportedMouse
    var onRunTest: () -> Void
    var onNotNow: () -> Void
    var onDontAsk: () -> Void
    /// Looked up once: the body reads both several times per render.
    private let support: RazerDevices.LinkSupport
    private let links: [RazerDevices.LinkToTest]

    init(mouse: UnsupportedMouse, onRunTest: @escaping () -> Void, onNotNow: @escaping () -> Void,
         onDontAsk: @escaping () -> Void) {
        self.mouse = mouse
        self.onRunTest = onRunTest
        self.onNotNow = onNotNow
        self.onDontAsk = onDontAsk
        support = RazerDevices.support(pid: mouse.pid)
        links = RazerDevices.linksToTest(besides: mouse.pid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if !mouse.canControl {
                needsAccessBody
            } else {
                switch support {
                case .full: otherLinksBody
                case .partly(let works, let missing): partlyBody(works: works, missing: missing)
                case .unknown: readyBody
                }
            }
            HStack(spacing: 10) {
                Button("Don't ask for this mouse", action: onDontAsk)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if mouse.canControl && support == .full {
                    // Nothing to run on this link. Got It ends the ask, like "Don't ask", but
                    // reads as the answer to a note rather than a refusal.
                    Button("Got It", action: onDontAsk)
                        .buttonStyle(RazerProminentButtonStyle())
                } else {
                    Button("Not Now", action: onNotNow)
                        .keyboardShortcut(.cancelAction)
                    // Not the default action: the window opens on its own, and Return pressed for
                    // something else shouldn't start a test.
                    Button(mouse.canControl ? "Run the Test" : "Get Started", action: onRunTest)
                        .buttonStyle(RazerProminentButtonStyle())
                }
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private var title: String {
        guard mouse.canControl else { return "We found a new Razer mouse" }
        switch support {
        case .full: return links.count > 1 ? "Test your mouse's other connections" : "Test your mouse's other connection"
        case .partly: return "Help finish support for your mouse"
        case .unknown: return "Help us support your mouse"
        }
    }

    /// The popover card's title and line, for the same three cases as the window.
    static func cardText(pid: Int) -> (title: String, detail: String) {
        switch RazerDevices.support(pid: pid) {
        case .full:
            return ("Test its other connection", linkSummary(RazerDevices.linksToTest(besides: pid)))
        case .partly(_, let missing):
            return ("Help finish support for this mouse",
                    "\(DeviceTestView.list(missing)) still \(missing.count == 1 ? "needs" : "need") testing. A short test checks just that.")
        case .unknown:
            return ("Help us support this mouse", "A 2-minute test shows us what it can do. You review the report before it's sent.")
        }
    }

    /// One line naming the links still to test, for the card.
    static func linkSummary(_ links: [RazerDevices.LinkToTest]) -> String {
        guard !links.isEmpty else { return "Verified on this connection." }
        let names = links.map { link -> String in
            switch link.connection {
            case .wired: return "its cable"
            case .wirelessDongle: return "its dongle"
            case .bluetooth: return "Bluetooth"
            }
        }
        let joined = names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "Verified on this connection. If your mouse also uses \(joined), a test there helps."
    }

    private var otherLinksBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MacRazer fully supports this mouse over \(connectionPhrase). Other ways it connects show up to MacRazer as a different mouse, so each needs its own test.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            linkCards
        }
    }

    private func partlyBody(works: [RazerFeature], missing: [RazerFeature]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MacRazer already supports part of this mouse. A short test checks only what's missing.")
                VStack(alignment: .leading, spacing: 4) {
                    labelled("Already works", DeviceTestView.list(works), color: .razerGreenText)
                    labelled("Still needs testing", DeviceTestView.list(missing), color: .batteryMid)
                }
            }
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            linkCards
            VStack(alignment: .leading, spacing: 8) {
                point("clock", "About a minute. You click a few buttons when asked.")
                point("eye", "You see the full report before anything is sent.")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// One note per other link still worth a test, worded as the device test words them.
    @ViewBuilder private var linkCards: some View {
        ForEach(links, id: \.connection) { link in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: link.connection == .bluetooth ? "dot.radiowaves.left.and.right" : "cable.connector")
                    .foregroundStyle(Color.razerGreenText)
                    .frame(width: 16)
                Text(DeviceTestView.linkText(link)).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func labelled(_ label: String, _ value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(color).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
    }

    /// "the 2.4 GHz dongle", "its cable", "Bluetooth".
    private var connectionPhrase: String {
        switch RazerDevices.connection(pid: mouse.pid) {
        case .wired?: return "its cable"
        case .wirelessDongle?: return "the 2.4 GHz dongle"
        case .bluetooth?: return "Bluetooth"
        case nil: return "this connection"
        }
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
                Text(title)
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

// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// About MacRazer.
///
/// More than a version number, because this app has things it genuinely owes the people
/// reading it: it uses Razer's trademarks descriptively and must say it isn't Razer's, and its
/// mouse protocol was ported from OpenRazer — which is why the project is GPL at all, and why
/// their credit belongs somewhere a user can actually see rather than only in `NOTICE.md`.
struct AboutView: View {
    var onDone: (() -> Void)?

    private enum Links {
        static let source = URL(string: "https://github.com/SorcRR/MacRazer")!
        static let issues = URL(string: "https://github.com/SorcRR/MacRazer/issues")!
        static let tip = URL(string: "https://ko-fi.com/sorcrr")!
        static let developer = URL(string: "https://github.com/SorcRR")!
        static let openRazer = URL(string: "https://github.com/openrazer/openrazer")!
        static let cobraPR = URL(string: "https://github.com/openrazer/openrazer/pull/2583")!
    }

    /// Real bundle values; the fallbacks only show under `swift run`, which has no bundle.
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            unofficialSection
            openRazerSection
            licenseSection
            footer
        }
        .padding(22)
        .frame(width: 460)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(Color.razerGreenBright.opacity(0.20))
                Image(nsImage: MenuBarIcon.mouse(pointSize: 32, razerCutout: true))
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Color.razerGreenBright)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("MacRazer").font(.system(size: 22, weight: .semibold))
                Text("Version \(version) (build \(build))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                HStack(spacing: 4) {
                    Text("by").font(.system(size: 12)).foregroundStyle(.secondary)
                    Link("SorcRR", destination: Links.developer)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.razerGreen)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Sections

    private var unofficialSection: some View {
        titledSection("Unofficial") {
            body("An independent community project. It is not affiliated with, authorized by, "
                 + "or endorsed by Razer Inc.")
            body("“Razer”, “Cobra”, “HyperSpeed”, “Synapse” and “Chroma” are trademarks of "
                 + "Razer Inc., used here only to describe compatibility. The app's mouse mark "
                 + "is its own; it does not display Razer's logo.")
        }
    }

    private var openRazerSection: some View {
        titledSection("Built on OpenRazer") {
            body("The device protocol — command bytes, the report structure, CRC, the Cobra "
                 + "command set — was ported from OpenRazer's Linux driver. The hard "
                 + "reverse-engineering is theirs.")
            body("Cobra HyperSpeed support follows OpenRazer PR #2583 by dyharlan, reviewed "
                 + "by z3ntu, which established that the device reuses the Cobra Pro protocol.")
            HStack(spacing: 14) {
                Link("OpenRazer", destination: Links.openRazer)
                Link("PR #2583", destination: Links.cobraPR)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.razerGreen)
        }
    }

    private var licenseSection: some View {
        titledSection("License") {
            body("GPL-2.0-or-later — GPL because it derives from OpenRazer, which is GPL.")
            body("Provided as is, without warranty of any kind. It talks to your mouse over "
                 + "HID; it only sends the same feature reports OpenRazer and Synapse use, but "
                 + "you run it at your own risk.")
            Link("View the source", destination: Links.source)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.razerGreen)
        }
    }

    // MARK: Footer

    /// Issues rather than an email address: reports land somewhere they can be tracked, and
    /// there is no address in a public binary for scrapers to harvest.
    private var footer: some View {
        HStack(spacing: 10) {
            Link(destination: Links.issues) {
                Label("Report an Issue", systemImage: "exclamationmark.bubble")
            }
            .buttonStyle(.bordered)
            Link(destination: Links.tip) {
                Label("Leave a Tip", systemImage: "heart")
            }
            .buttonStyle(.bordered)
            .tint(.razerGreen)
            Spacer(minLength: 0)
            Button("Done") { onDone?() }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .font(.system(size: 11.5))
    }

    private func body(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

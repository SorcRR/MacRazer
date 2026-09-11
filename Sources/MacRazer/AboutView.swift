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
    /// Not optional: a defaulted no-op would let a caller ship a Done button that depresses
    /// and does nothing, with no compiler error.
    var onDone: () -> Void

    /// Notes for the version this is the About box of, when the app has them. The popover's
    /// "Updated to …" card is shown once and then dismissed; this is where they stay
    /// findable afterwards, next to the version number they belong to.
    var notes: ReleaseNotes?

    @State private var showingNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            unofficialSection
            openRazerSection
            licenseSection
            hiveshipSection
            footer
        }
        .padding(22)
        .frame(width: 460)
        // Content that cannot be empty, rather than an `if let` inside the builder: the row
        // that sets `showingNotes` is gated on the same notes, but the two gates sit far apart
        // and a sheet with an empty body is a blank panel with no way out but Escape.
        .sheet(isPresented: $showingNotes) {
            WhatsNewPage(version: AppInfo.displayVersion,
                         notes: notes ?? ReleaseNotes(summary: "", sections: []),
                         canInstallInPlace: false,
                         onBack: { showingNotes = false },
                         onUpdate: nil) // already running it
                .frame(width: 380, height: 460)
        }
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
                Text("Version \(AppInfo.displayVersion) (build \(AppInfo.displayBuild))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                HStack(spacing: 4) {
                    Text("by").font(.system(size: 12)).foregroundStyle(.secondary)
                    Link("SorcRR", destination: ProjectLinks.developer)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.razerGreen)
                }
                whatsNewRow
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Sections

    private var unofficialSection: some View {
        titledSection("Unofficial") {
            sectionNote("An independent community project. Not affiliated with, authorized by, "
                        + "or endorsed by Razer Inc.")
            sectionNote("“Razer”, “Cobra”, “HyperSpeed”, “Synapse” and “Chroma” are trademarks of "
                        + "Razer Inc. They are used here only to say which mice this works with. "
                        + "The mouse icon is the app's own drawing, not Razer's logo.")
        }
    }

    private var openRazerSection: some View {
        titledSection("Built on OpenRazer") {
            sectionNote("Everything this app says to your mouse was ported from OpenRazer's Linux "
                        + "driver: the command bytes, the report structure, the CRC, the Cobra "
                        + "command set. They did the hard reverse engineering.")
            sectionNote("Cobra HyperSpeed support follows their PR #2583 by dyharlan, reviewed by "
                        + "z3ntu, which worked out that the mouse reuses the Cobra Pro protocol.")
            HStack(spacing: 14) {
                Link("OpenRazer", destination: ProjectLinks.openRazer)
                Link("PR #2583", destination: ProjectLinks.cobraHyperSpeedPR)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.razerGreen)
        }
    }

    private var licenseSection: some View {
        titledSection("License") {
            sectionNote("GPL-2.0-or-later. It has to be GPL, because it builds on OpenRazer.")
            sectionNote("Provided as is, with no warranty of any kind. It talks to your mouse over "
                        + "HID and only sends the same feature reports OpenRazer and Synapse do, "
                        + "but you run it at your own risk.")
            Link("View the source", destination: ProjectLinks.repo)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.razerGreen)
        }
    }

    // MARK: What's new

    /// Sits under the version because that is the question it answers. Shown only when the
    /// app actually has the notes for the version running — a row that opened an empty page
    /// would be worse than no row.
    @ViewBuilder
    private var whatsNewRow: some View {
        if notes != nil {
            Button { showingNotes = true } label: {
                HStack(spacing: 4) {
                    Text("What's new in \(AppInfo.displayVersion)")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.razerGreen)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: For developers

    /// The one piece of this window that is not about MacRazer.
    ///
    /// It describes what Hiveship is and stops there. It does not say MacRazer's own work is
    /// planned or tracked in it — that board is not public, so a reader who clicked on the
    /// strength of "tracked here" would land on a signup page instead of the thing they were
    /// promised. Saying what the product does and offering a button asks for the same click
    /// without setting up that gap.
    ///
    /// In About rather than the popover: the popover is opened daily to read a battery
    /// percentage, and nothing permanent there stays subtle past the third time you see it.
    private var hiveshipSection: some View {
        titledSection("For developers") {
            sectionNote("MacRazer was built with Hiveship. It's an issue tracker for planning "
                        + "work, tracking bugs, and handing issues to coding agents as well as "
                        + "the people on your team.")
            Link(destination: ProjectLinks.hiveship) {
                Label("Go to Hiveship", systemImage: "arrow.up.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: Footer

    /// Issues rather than an email address: reports land somewhere they can be tracked, and
    /// there is no address in a public binary for scrapers to harvest.
    private var footer: some View {
        HStack(spacing: 10) {
            Link(destination: ProjectLinks.issues) {
                Label("Report an Issue", systemImage: "exclamationmark.bubble")
            }
            .buttonStyle(.bordered)
            Link(destination: ProjectLinks.tip) {
                Label("Leave a Tip", systemImage: "heart")
            }
            .buttonStyle(.bordered)
            .tint(.razerGreen)
            Spacer(minLength: 0)
            Button("Done") { onDone() }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .font(.system(size: 11.5))
    }
}

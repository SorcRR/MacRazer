// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The release notes for a pending update, given the whole popover.
///
/// A sub-page rather than an expanding section in the update card: the main page already
/// fills the height a menu bar popover can reasonably use, so notes shown inline would push
/// the cards below them off screen. Reached from one chevron row in the card, the same way
/// Buttons, Usage and Profiles are reached.
struct WhatsNewPage: View {
    let version: String
    let notes: ReleaseNotes
    /// Drives the button's wording: an in-place install ends in a relaunch, a plain download
    /// doesn't, and the button should never promise the restart it can't deliver.
    let canInstallInPlace: Bool
    let onBack: () -> Void
    /// Nil when there is nothing to install — the notes are about the version already running,
    /// and a button offering to fetch it again would be nonsense.
    let onUpdate: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.razerGreen)
                Text("What's new in \(version)").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !notes.summary.isEmpty {
                        Text(notes.summary)
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Indexed rather than keyed by title: nothing stops a release body from
                    // using the same heading twice, and the untitled section has no key at all.
                    ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 8) {
                            if !section.title.isEmpty {
                                Text(section.title.uppercased())
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .kerning(0.6)
                            }
                            // Indexed: two releases can carry the same headline, and an
                            // identical bullet twice in one section is legal markdown.
                            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                itemRow(item)
                            }
                        }
                    }
                    Link("Full release notes", destination: ProjectLinks.latestRelease)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.razerGreen)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Repeated from the card so the decision can be made where the information is,
            // without navigating back to find the button again.
            if let onUpdate {
                Button(action: onUpdate) {
                    HStack(spacing: 6) {
                        Image(systemName: canInstallInPlace ? "arrow.triangle.2.circlepath" : "arrow.down.to.line")
                        Text(canInstallInPlace ? "Update & Restart" : "Download")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .tint(.razerGreen)
                .controlSize(.small)
                .padding(12)
            }
        }
    }

    /// Markdown as an `AttributedString`, so a link in a release note is a link.
    ///
    /// Falls back to the plain text when the markdown will not parse. A release body is prose
    /// somebody typed, and a page that renders nothing because one bullet had a stray bracket
    /// would be a worse failure than one that renders it flat.
    private static func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(ReleaseNotes.strip(markdown))
    }

    @ViewBuilder
    private func itemRow(_ item: ReleaseNotes.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !item.headline.isEmpty {
                Text(Self.rendered(item.headlineSource))
                    .font(.system(size: 11.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.detail.isEmpty {
                Text(Self.rendered(item.detailSource))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

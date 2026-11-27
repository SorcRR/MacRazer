// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The popover's card shape, matched to the app's own `card` so the holiday ones sit in line.
private func holidayCard<Content: View>(tinted: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
    content()
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tinted ? AnyShapeStyle(HolidayColor.blush) : AnyShapeStyle(Color.primary.opacity(0.10)),
                    in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            if tinted { RoundedRectangle(cornerRadius: 13).strokeBorder(HolidayColor.pink.opacity(0.8), lineWidth: 0.5) }
        }
}

/// The line under the header: the countdown, or the day's greeting.
public struct HolidayHeadline: View {
    @ObservedObject private var holiday = Holiday.shared
    public init() {}

    public var body: some View {
        if holiday.isFestive, let text = holiday.headline {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(text).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(holiday.phase == .newYearsDay ? HolidayColor.bronze : HolidayColor.red)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var symbol: String {
        switch holiday.phase {
        case .christmasEve: "moon.stars"
        case .christmasDay, .afterChristmas: "star"
        case .newYearsDay: "sparkles"
        case .windDown, .lastDay: "shippingbox"
        default: "snowflake"
        }
    }
}

/// The first-open banner, and on the last day the notice that the decorations come down.
/// The app shows this only when it has no notice of its own to show: an update, a crash
/// report or a connection problem always comes first.
public struct HolidayNotice: View {
    @ObservedObject private var holiday = Holiday.shared
    /// The person's own theme, named in the banner as what they'd go back to.
    let themeName: String
    public init(themeName: String) { self.themeName = themeName }

    public var body: some View {
        if holiday.bannerPending {
            banner
                .onAppear { holiday.setBannerInView(true) }
                .onDisappear { holiday.setBannerInView(false) }
        } else if holiday.endingNoticePending {
            ending
        }
    }

    private var banner: some View {
        holidayCard(tinted: true) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "gift").font(.system(size: 17)).foregroundStyle(HolidayColor.deepRed)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your mouse got festive").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(HolidayColor.wine)
                    Text("Holiday decorations are on until Jan 6. Keep them, or go back to your \(themeName) theme. You can switch any time in Settings.")
                        .font(.system(size: 11)).foregroundStyle(HolidayColor.deepRed)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Keep it") { holiday.keep() }
                            .buttonStyle(HolidayPillButton(filled: true))
                        Button("Turn off decorations") { holiday.turnOffFromBanner() }
                            .buttonStyle(HolidayPillButton(filled: false))
                    }
                    .padding(.top, 5)
                }
            }
        }
    }

    private var ending: some View {
        holidayCard(tinted: true) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shippingbox").font(.system(size: 16)).foregroundStyle(HolidayColor.deepRed)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Last day of the holidays").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(HolidayColor.wine)
                    Text("Decorations come down tonight and come back next December. Your \(themeName) theme returns tomorrow.")
                        .font(.system(size: 11)).foregroundStyle(HolidayColor.deepRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { holiday.dismissEndingNotice() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(HolidayColor.deepRed)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
    }
}

struct HolidayPillButton: ButtonStyle {
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(filled ? HolidayColor.blush : HolidayColor.wine)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(filled ? AnyShapeStyle(HolidayColor.deepRed) : AnyShapeStyle(Color.clear), in: Capsule())
            .overlay { if !filled { Capsule().strokeBorder(HolidayColor.pink, lineWidth: 0.5) } }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// The score, the level and how far to the next one. Shows after the first catch.
public struct HolidayScoreLine: View {
    @ObservedObject private var holiday = Holiday.shared
    @ObservedObject private var game = HolidayGame.shared
    @ObservedObject private var leaderboard = HolidayLeaderboard.shared
    private let onLeaderboard: (() -> Void)?

    /// `onLeaderboard` opens the leaderboard page; the link shows only while there is one.
    public init(onLeaderboard: (() -> Void)? = nil) { self.onLeaderboard = onLeaderboard }

    public var body: some View {
        // Nothing until the first catch: then the score, and the leaderboard link under it.
        if holiday.isFestive, game.score > 0 {
            VStack(alignment: .leading, spacing: 4) {
                score
                if showsLink { link }
            }
            .padding(.horizontal, 4)
        }
    }

    private var showsLink: Bool { onLeaderboard != nil && leaderboard.isAvailable }

    private var score: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised").font(.system(size: 10.5, weight: .semibold))
                Text("Score \(game.score)").font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 4)
                Text("Level \(game.level + 1) of \(HolidayGameRules.levelThresholds.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .foregroundStyle(HolidayColor.red)
            ProgressView(value: HolidayGameRules.progress(for: game.score))
                .progressViewStyle(.linear)
                .tint(HolidayColor.deepRed)
                .controlSize(.mini)
            Text(breakdown).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(next).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var link: some View {
        Button { onLeaderboard?() } label: {
            HStack(spacing: 5) {
                Image(systemName: "trophy.fill").font(.system(size: 10)).foregroundStyle(HolidayColor.gold)
                Text(leaderboard.joined ? "Leaderboard" : "Join the Santa leaderboard")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(HolidayColor.red)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .accessibilityLabel(leaderboard.joined ? "Santa leaderboard" : "Join the Santa leaderboard")
    }

    /// Every character caught so far, Settings' ones included, so the parts add up to the score.
    private var breakdown: String {
        HolidayCharacter.allCases.compactMap { character in
            guard let n = game.counts[character], n > 0 else { return nil }
            return "\(n) \(character.countName(n))"
        }.joined(separator: " · ")
    }

    private var next: String {
        guard let left = HolidayGameRules.pointsToNextLevel(from: game.score) else { return "Top level reached" }
        return "\(left) more until he gets faster"
    }
}

/// Settings › Appearance: the switch, all season, and the score once there is one.
public struct HolidaySettingsRow: View {
    @ObservedObject private var holiday = Holiday.shared
    @ObservedObject private var game = HolidayGame.shared
    @ObservedObject private var presents = HolidayPresents.shared
    public init() {}

    public var body: some View {
        if holiday.showsSettingsRow {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(get: { holiday.decorationsOn }, set: { holiday.setDecorations(on: $0) })) {
                    HStack(spacing: 8) {
                        HolidayTreeIcon(star: holiday.phase?.hasStar ?? false).frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Holiday decorations").font(.system(size: 13))
                            Text("Dec 1 to Jan 6. Your theme stays the same underneath.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .tint(HolidayColor.deepRed)
                // Dec 24 to 26: brings back presents hidden from the popover.
                if holiday.presentsStage != nil {
                    Toggle(isOn: Binding(get: { !presents.hidden }, set: { presents.setHidden(!$0) })) {
                        HStack(spacing: 8) {
                            Image(systemName: "gift").font(.system(size: 12)).foregroundStyle(HolidayColor.red)
                                .frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Presents under the tree").font(.system(size: 13))
                                Text("In the popover on Dec 25 and 26.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .tint(HolidayColor.deepRed)
                    .padding(.top, 4)
                }
                if game.score > 0 {
                    Text("Score \(game.score) · Level \(game.level + 1) of \(HolidayGameRules.levelThresholds.count)")
                        .font(.system(size: 11)).foregroundStyle(HolidayColor.red)
                        .padding(.leading, 24)
                }
            }
        }
    }
}

/// The tree in the popover's header, where the mouse's icon usually is.
public struct HolidayHeaderIcon: View {
    @ObservedObject private var holiday = Holiday.shared
    public init() {}
    public var body: some View {
        HolidayTreeIcon(star: holiday.phase?.hasStar ?? false)
    }
}

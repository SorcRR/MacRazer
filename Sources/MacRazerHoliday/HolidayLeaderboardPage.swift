// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The popover's leaderboard page: join with a festive name, then the top ten and your own
/// place. The board is fetched when the page opens, never in the background.
public struct HolidayLeaderboardPage: View {
    @ObservedObject private var holiday = Holiday.shared
    @ObservedObject private var board = HolidayLeaderboard.shared
    @ObservedObject private var game = HolidayGame.shared
    private let onBack: () -> Void
    @State private var expanded: String?
    @State private var renaming = false
    @State private var draft = ""

    public init(onBack: @escaping () -> Void) { self.onBack = onBack }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if board.isAvailable {
                if !board.joined || renaming { joinCard } else { youCard }
                if board.boardUnreachable && board.board == nil {
                    offlineCard
                } else {
                    if board.boardUnreachable { offlineNote }
                    if board.hasPlayers { rows } else { emptyCard }
                }
                footnote
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { board.setPageVisible(true) }
        .onDisappear { board.setPageVisible(false) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HolidayBackButton(action: onBack)
            VStack(alignment: .leading, spacing: 1) {
                Text("Santa leaderboard").font(.system(size: 16, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "trophy.fill").font(.system(size: 15)).foregroundStyle(HolidayColor.gold)
                .accessibilityHidden(true)
        }
    }

    private var subtitle: String {
        let season = holiday.storageSeason.map { "\($0) season" } ?? "This season"
        let count = board.board?.playerCount ?? 0
        let players = count == 1 ? "1 player" : "\(count) players"
        if board.isFinalDay { return "\(season) · \(players) · final scores tonight" }
        return "\(season) · \(players)"
    }

    // MARK: Joining

    private var joinCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(renaming ? "Change your name" : "Join the board")
                .font(.system(size: 13, weight: .semibold))
            if !renaming {
                Text("Your score, catches and gifts show next to a festive name. No account and nothing else "
                     + "about you. Leave any time and your row is deleted.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                TextField("Festive name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .accessibilityLabel("Your name on the board")
                Button {
                    board.shuffleName()
                    draft = board.suggestedName
                } label: {
                    Image(systemName: "shuffle").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                }
                .help("Another name")
                .accessibilityLabel("Suggest another name")
            }
            if !draft.isEmpty, HolidayLeaderboard.cleaned(draft) == nil {
                Text("3 to 24 letters, numbers and spaces.")
                    .font(.system(size: 11)).foregroundStyle(HolidayColor.red)
            } else if let problem = board.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(HolidayColor.red)
            }
            HStack(spacing: 8) {
                Button(renaming ? "Save" : "Join as \(HolidayLeaderboard.cleaned(draft) ?? "…")", action: submit)
                    .buttonStyle(HolidayPillButton(filled: true))
                    .disabled(HolidayLeaderboard.cleaned(draft) == nil || board.joining)
                if board.joining { ProgressView().controlSize(.small).accessibilityLabel("Joining") }
                if renaming {
                    Button("Cancel") { renaming = false }.buttonStyle(HolidayPillButton(filled: false))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { if draft.isEmpty { draft = board.name ?? board.suggestedName } }
    }

    private func submit() {
        Task {
            if await board.join(as: draft) { renaming = false }
        }
    }

    private var youCard: some View {
        HStack(spacing: 10) {
            Group {
                if let rank = board.rank {
                    Text("#\(rank)").font(.system(size: 18, weight: .bold, design: .rounded))
                } else {
                    // No place until the board opens.
                    Image(systemName: "person.fill").font(.system(size: 16))
                }
            }
            .foregroundStyle(HolidayColor.red)
            .frame(minWidth: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("Playing as \(board.name ?? "")").font(.system(size: 12.5, weight: .semibold))
                Text(youLine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Change name…") {
                    draft = board.name ?? ""
                    renaming = true
                }
                Button("Leave the board", role: .destructive) { board.leave() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Name and leaving")
        }
        .padding(12)
        .background(HolidayColor.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private var youLine: String {
        let score = "Score \(game.score)"
        guard let rank = board.rank, let count = board.board?.playerCount else { return score }
        return "\(score) · #\(rank) of \(count)"
    }

    // MARK: The board

    /// Nobody has joined this season yet.
    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nobody on the board yet")
                .font(.system(size: 12.5, weight: .semibold))
            Text(board.joined ? "Your score shows here in a moment." : "Join with a festive name and be the first.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    /// No board to show: the Worker couldn't be reached.
    private var offlineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("No connection").font(.system(size: 12.5, weight: .semibold))
            }
            Text("The board can't be checked right now. Your score keeps counting on this Mac and goes "
                 + "up once you're back online.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { board.syncThenRefresh() }
                .buttonStyle(HolidayPillButton(filled: false))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    /// A board from earlier, and no connection to check it now.
    private var offlineNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash").font(.system(size: 10.5))
            Text("No connection. This is the board from earlier.").font(.system(size: 11))
            Spacer(minLength: 4)
            Button("Try again") { board.syncThenRefresh() }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(HolidayColor.red)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(board.visibleRows, id: \.player.id) { row in
                if row.gapAbove {
                    Image(systemName: "ellipsis").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .accessibilityHidden(true)
                }
                LeaderboardRow(rank: row.rank, player: row.player, expanded: expanded == row.player.id) {
                    withAnimation(holiday.stillMode ? nil : .easeOut(duration: 0.18)) {
                        expanded = expanded == row.player.id ? nil : row.player.id
                    }
                }
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footnote: some View {
        Text(footnoteText)
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

extension HolidayLeaderboardPage {
    private var footnoteText: String {
        if board.isFinalDay { return "Scores stand at midnight. A new board starts next December." }
        return board.hasPlayers ? "Scores count until Jan 6. Click a row for the catches." : "Scores count until Jan 6."
    }
}

/// One player: place, name, gifts and score. Click for the catches and the gifts by name.
private struct LeaderboardRow: View {
    let rank: Int
    let player: HolidayPlayer
    let expanded: Bool
    let onToggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    RankBadge(rank: rank)
                    Text(player.name)
                        .font(.system(size: 12.5, weight: player.isYou ? .bold : .regular))
                        .lineLimit(1)
                    if player.isYou {
                        Text("You").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(HolidayColor.red, in: Capsule())
                    }
                    Spacer(minLength: 4)
                    GiftSlots(gifts: player.giftsRarestFirst)
                    Text("\(player.score)")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(minWidth: 34, alignment: .trailing)
                }
                if expanded { details }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint(expanded ? "Hides the catches" : "Shows the catches")
        .accessibilityAddTraits(.isButton)
    }

    private var background: Color {
        if player.isYou { return HolidayColor.red.opacity(0.14) }
        return hovered || expanded ? Color.primary.opacity(0.07) : .clear
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(catches).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(giftNames).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.leading, 34)
    }

    private var catches: String {
        let parts = HolidayCharacter.allCases.compactMap { character -> String? in
            guard let n = player.counts[character], n > 0 else { return nil }
            return "\(n) \(character.countName(n))"
        }
        return parts.isEmpty ? "No catches yet" : parts.joined(separator: " · ")
    }

    private var giftNames: String {
        player.gifts.isEmpty ? "No presents opened"
            : "Presents: " + player.giftsRarestFirst.map(\.name).joined(separator: ", ")
    }

    private var spoken: String {
        var text = "Number \(rank), \(player.name)\(player.isYou ? ", you" : ""), score \(player.score)"
        if !player.gifts.isEmpty { text += ", " + player.giftsRarestFirst.map(\.name).joined(separator: ", ") }
        if expanded { text += ". \(catches)" }
        return text
    }
}

/// Gold, silver and bronze for the top three; a plain number after that.
private struct RankBadge: View {
    let rank: Int

    var body: some View {
        ZStack {
            if let medal { Circle().fill(medal) }
            Text("\(rank)")
                .font(.system(size: rank > 99 ? 9.5 : 11, weight: .bold, design: .rounded))
                .foregroundStyle(medal == nil ? Color.secondary : HolidayColor.ink)
        }
        .frame(width: 26, height: 22)
    }

    private var medal: Color? {
        switch rank {
        case 1: HolidayColor.paleGold
        case 2: Color(hex: 0xD3D6DB)
        case 3: Color(hex: 0xE0A878)
        default: nil
        }
    }
}

/// Three slots: the gifts opened, rarest first, then dashed empty ones.
private struct GiftSlots: View {
    let gifts: [HolidayGift]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<HolidayPresents.count, id: \.self) { i in
                if i < gifts.count {
                    Text(gifts[i].emoji).font(.system(size: 12))
                        .frame(width: 18, height: 18)
                        .background(gifts[i].rarity == .regular ? Color.clear : HolidayColor.paleGold.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 4))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(width: 18, height: 18)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The popover's Back button, as the app draws it, with Esc.
struct HolidayBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text("Back").font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.primary.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Back (Esc)")
    }
}

/// Settings › Privacy, once joined: what's on the board, and leaving it.
public struct HolidayPrivacyRow: View {
    @ObservedObject private var board = HolidayLeaderboard.shared
    @State private var confirming = false

    public init() {}

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "trophy.fill").font(.system(size: 13)).foregroundStyle(HolidayColor.gold)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Playing as \(board.name ?? "")").font(.system(size: 13))
                Text("Your name, score, catches and presents are on the board until January. "
                     + "Leaving deletes them there. Your score stays on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Leave…") { confirming = true }
                .controlSize(.small)
        }
        .confirmationDialog("Leave the Santa leaderboard?", isPresented: $confirming) {
            Button("Leave", role: .destructive) { board.leave() }
        } message: {
            Text("Your row is deleted from the board. You can join again any time this season.")
        }
    }
}

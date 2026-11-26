// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The size of a peeking character, and how much of it shows: the whole face, just inside the
/// card's edge. It may sit over a control for the second or so it's out.
private let characterSize: CGFloat = 30
private let showing: CGFloat = 30

/// Makes a card a place the game's characters can peek out of. Only the character itself
/// takes clicks, and only while it's out; the card works exactly as before.
struct HolidayPeekSpot: ViewModifier {
    let surface: HolidaySurface
    let cornerRadius: CGFloat
    /// The edges a character may come out of here; one the game picks elsewhere maps onto these.
    let edges: [PeekEdge]
    @ObservedObject var holiday: Holiday
    @ObservedObject var game: HolidayGame
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .overlay {
                if holiday.isFestive, let peek = game.peek, peek.spot == id {
                    GeometryReader { geo in
                        PeekingCharacter(peek: peek, edge: allowed(peek.edge), size: geo.size) { game.caught(peek.id) }
                            .id(peek.id)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
            .overlay(alignment: .top) {
                if let bubble = game.bubble, bubble.spot == id {
                    CatchBubble(bubble: bubble).id(bubble.id)
                }
            }
            .onHover { game.setHovered(id, $0) }
            .onAppear { game.register(id, surface: surface) }
            .onDisappear { game.unregister(id) }
    }

    private func allowed(_ edge: PeekEdge) -> PeekEdge {
        guard !edges.isEmpty, !edges.contains(edge) else { return edge }
        return edges[(PeekEdge.allCases.firstIndex(of: edge) ?? 0) % edges.count]
    }
}

/// One character sliding out from an edge, and back in just before its time is up.
private struct PeekingCharacter: View {
    let peek: HolidayPeek
    let edge: PeekEdge
    let size: CGSize
    let onCatch: () -> Void
    @State private var out = PeekingCharacter.startsOut

    /// Still renders (`MACRAZER_HOLIDAY_PEEK`) catch it already out, not mid-slide.
    private static var startsOut: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["MACRAZER_HOLIDAY_PEEK"] != nil
        #else
        false
        #endif
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            let glow = 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi)
            HolidayCharacterArt(character: peek.character, glow: glow)
        }
        .frame(width: characterSize, height: characterSize)
        .rotationEffect(rotation)
        .contentShape(Circle())
        .onTapGesture(perform: onCatch)
        .accessibilityElement()
        .accessibilityLabel("\(peek.character.spokenName) is peeking out. Catch them")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onCatch() }
        .position(out ? shownCenter : hiddenCenter)
        .onAppear {
            withAnimation(.easeOut(duration: HolidayGameRules.slideSeconds)) { out = true }
        }
        .task {
            let stay = max(0.1, peek.seconds - HolidayGameRules.slideSeconds * 2)
            try? await Task.sleep(for: .seconds(HolidayGameRules.slideSeconds + stay))
            withAnimation(.easeIn(duration: HolidayGameRules.slideSeconds)) { out = false }
        }
    }

    private var rotation: Angle {
        switch edge {
        case .bottom: .zero
        case .top: .degrees(180)
        case .trailing: .degrees(-90)
        }
    }

    private var along: CGFloat {
        switch edge {
        case .bottom, .top: min(max(peek.position * size.width, characterSize), size.width - characterSize)
        case .trailing: min(max(peek.position * size.height, characterSize / 2), max(characterSize / 2, size.height - characterSize / 2))
        }
    }

    private var shownCenter: CGPoint {
        let inset = characterSize / 2 - showing
        switch edge {
        case .bottom: return CGPoint(x: along, y: size.height + inset)
        case .top: return CGPoint(x: along, y: -inset)
        case .trailing: return CGPoint(x: size.width + inset, y: along)
        }
    }

    private var hiddenCenter: CGPoint {
        let away = characterSize / 2 + 2
        switch edge {
        case .bottom: return CGPoint(x: along, y: size.height + away)
        case .top: return CGPoint(x: along, y: -away)
        case .trailing: return CGPoint(x: size.width + away, y: along)
        }
    }
}

/// "Ho ho ho!" floating up over the card and fading.
private struct CatchBubble: View {
    let bubble: HolidayBubble
    @State private var risen = false

    var body: some View {
        Text(bubble.text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(HolidayColor.blush)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(fill, in: Capsule())
            .offset(y: risen ? -14 : 4)
            .opacity(risen ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeOut(duration: 1.25)) { risen = true }
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: bubble.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
    }

    private var fill: Color {
        switch bubble.character {
        case .santa: HolidayColor.deepRed
        case .reindeer: HolidayColor.brown
        case .elf: HolidayColor.darkGreen
        case .krampus: HolidayColor.bark
        }
    }
}

extension View {
    /// Lets the holiday characters peek out of this card. The plain card whenever the
    /// decorations are off.
    /// `edges` limits where they come out, for a spot with something on one of its edges.
    public func holidayPeekSpot(_ surface: HolidaySurface, cornerRadius: CGFloat = 13,
                                edges: [PeekEdge] = PeekEdge.allCases) -> some View {
        modifier(HolidayPeekSpot(surface: surface, cornerRadius: cornerRadius, edges: edges, holiday: .shared, game: .shared))
    }
}

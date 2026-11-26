// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine

/// Which edge of a card a character peeks out from.
public enum PeekEdge: CaseIterable, Sendable {
    case bottom, top, trailing
}

/// One character out of hiding: on which card, from which edge, and where along it.
public struct HolidayPeek: Equatable, Sendable {
    public let id: UUID
    public let spot: UUID
    public let character: HolidayCharacter
    public let edge: PeekEdge
    /// Where along the edge, 0 to 1.
    public let position: Double
    /// How long it stays out, slide included.
    public let seconds: Double
}

/// A "Ho ho ho!" over the card a character was caught on.
public struct HolidayBubble: Equatable, Sendable {
    public let id: UUID
    public let spot: UUID
    public let text: String
    public let character: HolidayCharacter
}

/// What the app's popover delegate tells the module: the popover really opened or closed.
/// SwiftUI's own appear and disappear can't say this, because the app builds the popover's
/// views ahead of time, before anyone opens it.
public enum HolidayPopover {
    @MainActor public static func didShow() {
        Holiday.shared.setPopoverOpen(true)
        HolidayGame.shared.setVisible(.popover, true)
    }

    @MainActor public static func didClose() {
        Holiday.shared.setPopoverOpen(false)
        HolidayGame.shared.setVisible(.popover, false)
    }
}

/// The catch game. Cards register as places to peek from; the game picks one at a time, keeps
/// the score and the level, and stays out of the way of the real app: nothing peeks from the
/// card under the pointer, nothing peeks for a few seconds after a real click or while
/// something's being dragged, and nothing runs while the popover or window is closed.
@MainActor
public final class HolidayGame: ObservableObject {
    public static let shared = HolidayGame(holiday: .shared)

    @Published public private(set) var peek: HolidayPeek?
    @Published public private(set) var bubble: HolidayBubble?
    @Published public private(set) var score = 0
    @Published public private(set) var counts: [HolidayCharacter: Int] = [:]

    private let holiday: Holiday
    private struct Spot { let surface: HolidaySurface; var hovered = false }
    private var spots: [UUID: Spot] = [:]
    private var visibleSurfaces: Set<HolidaySurface> = []
    private var loops: [HolidaySurface: Task<Void, Never>] = [:]
    private var lastSpot: [HolidaySurface: UUID] = [:]
    private var justCaught: [HolidaySurface: Bool] = [:]
    /// The last real click or drag in one of the app's windows: nothing peeks right after one.
    private var lastInteraction: Date?
    private var clickMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    /// After a level-up, a couple of peeks halfway between the old speed and the new.
    private var warmUpFrom: Int?
    private var warmUpLeft = 0
    private var random: () -> Double

    /// How long nothing peeks after a real click or drag.
    static let quietAfterInteraction: TimeInterval = 3

    public init(holiday: Holiday, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.holiday = holiday
        self.random = random
        load()
        holiday.$isFestive.combineLatest(holiday.$stillMode)
            .sink { [weak self] _, _ in self?.restartAll() }
            .store(in: &cancellables)
    }

    public var level: Int { HolidayGameRules.level(for: score) }

    // MARK: What the views tell the game

    func register(_ id: UUID, surface: HolidaySurface) {
        spots[id] = Spot(surface: surface)
        #if DEBUG
        // `MACRAZER_HOLIDAY_PEEK=reindeer` (any character) shows one at once on the first
        // card, for still renders of the popover and Settings.
        if peek == nil, let name = ProcessInfo.processInfo.environment["MACRAZER_HOLIDAY_PEEK"],
           let character = HolidayCharacter(rawValue: name) {
            _ = forcePeek(character, spot: id)
        }
        #endif
    }

    func unregister(_ id: UUID) {
        spots[id] = nil
        if peek?.spot == id { peek = nil }
    }

    func setHovered(_ id: UUID, _ hovered: Bool) {
        spots[id]?.hovered = hovered
    }

    /// The popover opened or closed, or the Settings window came and went.
    public func setVisible(_ surface: HolidaySurface, _ visible: Bool) {
        if visible { visibleSurfaces.insert(surface) } else { visibleSurfaces.remove(surface) }
        if !visible, let peek, spots[peek.spot]?.surface == surface { self.peek = nil }
        updateClickMonitor()
        restart(surface)
    }

    /// A click on the character showing on this card. Ignored if it already left.
    @discardableResult
    func caught(_ peekID: UUID) -> Bool {
        guard let peek, peek.id == peekID, let surface = spots[peek.spot]?.surface else { return false }
        self.peek = nil
        // The click that caught it isn't a click on the app: no quiet time after it.
        lastInteraction = nil
        let before = level
        score += peek.character.points
        counts[peek.character, default: 0] += 1
        if level > before { warmUpFrom = before; warmUpLeft = HolidayGameRules.warmUpPeeks }
        save()
        holiday.recordPlayedOnce()
        let bubble = HolidayBubble(id: UUID(), spot: peek.spot, text: peek.character.catchLine, character: peek.character)
        self.bubble = bubble
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            if self?.bubble == bubble { self?.bubble = nil }
        }
        justCaught[surface] = true
        restart(surface)
        return true
    }

    // MARK: The loop

    private func restartAll() {
        for surface in HolidaySurface.allCases { restart(surface) }
    }

    private func restart(_ surface: HolidaySurface) {
        loops[surface]?.cancel()
        loops[surface] = nil
        guard holiday.isFestive, !holiday.stillMode, visibleSurfaces.contains(surface) else {
            if let peek, spots[peek.spot]?.surface == surface { self.peek = nil }
            return
        }
        loops[surface] = Task { [weak self] in await self?.run(surface) }
    }

    private func run(_ surface: HolidaySurface) async {
        while !Task.isCancelled {
            let gap = HolidayGameRules.gap(score: score, justCaught: justCaught[surface] ?? false)
            justCaught[surface] = false
            try? await Task.sleep(for: .seconds(pick(in: gap)))
            // Wait for a moment with no real click and a card that isn't under the pointer.
            var spot = eligibleSpot(on: surface)
            while !Task.isCancelled, spot == nil {
                try? await Task.sleep(for: .seconds(1))
                spot = eligibleSpot(on: surface)
            }
            guard !Task.isCancelled, let spot else { return }
            let character = random() < 1 / Double(surface.bonusOneIn) ? surface.bonus : surface.regular
            let warm = warmUpLeft > 0 ? warmUpFrom : nil
            if warmUpLeft > 0 { warmUpLeft -= 1 }
            let seconds = HolidayGameRules.visible(character, level: level, warmingUpFrom: warm)
            let peek = HolidayPeek(id: UUID(), spot: spot, character: character,
                                   edge: PeekEdge.allCases[Int(random() * 3) % 3],
                                   position: 0.15 + random() * 0.65, seconds: seconds)
            lastSpot[surface] = spot
            self.peek = peek
            try? await Task.sleep(for: .seconds(seconds))
            // Caught meanwhile: `caught` started a fresh loop with the short gap.
            if self.peek?.id == peek.id { self.peek = nil } else { return }
        }
    }

    private func eligibleSpot(on surface: HolidaySurface) -> UUID? {
        if let last = lastInteraction, holiday.now().timeIntervalSince(last) < Self.quietAfterInteraction { return nil }
        let choices = spots.filter { $0.value.surface == surface && !$0.value.hovered }.map(\.key)
        let fresh = choices.filter { $0 != lastSpot[surface] }
        let pool = fresh.isEmpty ? choices : fresh
        guard !pool.isEmpty else { return nil }
        return pool.sorted { $0.uuidString < $1.uuidString }[min(Int(random() * Double(pool.count)), pool.count - 1)]
    }

    private func pick(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + random() * (range.upperBound - range.lowerBound)
    }

    /// Watches clicks and drags in the app's own windows, only while a game surface is open.
    /// It only notes the time; the event goes on untouched.
    private func updateClickMonitor() {
        if visibleSurfaces.isEmpty {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        } else if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated { self?.lastInteraction = self?.holiday.now() }
                return event
            }
        }
    }

    // MARK: Storage

    private func load() {
        score = holiday.stored(Int.self, "score") ?? 0
        let raw = holiday.stored([String: Int].self, "counts") ?? [:]
        counts = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in HolidayCharacter(rawValue: k).map { ($0, v) } })
    }

    private func save() {
        holiday.setStored(score, "score")
        holiday.setStored(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }), "counts")
    }

    /// A new season starts at zero: the stored values are per season, so reading them again
    /// on a season change gives the new season's.
    public func reloadForSeason() { load() }

    #if DEBUG
    /// For tests: show a peek straight away on a registered spot.
    func forcePeek(_ character: HolidayCharacter, spot: UUID) -> HolidayPeek {
        let p = HolidayPeek(id: UUID(), spot: spot, character: character, edge: .bottom, position: 0.5, seconds: 2)
        peek = p
        return p
    }
    #endif
}

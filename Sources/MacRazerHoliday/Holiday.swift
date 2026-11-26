// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import Combine

/// A change the person made, for the reports page's anonymous holiday count. Raw values are
/// what the Worker stores, so they never change once shipped.
public enum HolidayChange: String, CaseIterable, Sendable {
    /// "Keep it" on the first-open banner.
    case kept
    /// "Turn off decorations" on the banner, or the Settings switch before answering it.
    case offAtBanner = "off_at_banner"
    /// The banner came and went three times with no answer. The decorations stay on.
    case bannerIgnored = "banner_ignored"
    /// Turned off in Settings after keeping them, by how many days they were kept.
    case offLater0to1 = "off_later_0_1"
    case offLater2to3 = "off_later_2_3"
    case offLater4to7 = "off_later_4_7"
    case offLater8to14 = "off_later_8_14"
    case offLater15plus = "off_later_15_plus"
    /// Turned back on in Settings after turning them off.
    case onLater = "on_later"
    /// The first catch of the season, once.
    case played
    /// The presents card hidden with its close button, once a season.
    case presentsHidden = "presents_hidden"

    /// The bucket for decorations turned off after this many whole days.
    static func offLater(afterDays days: Int) -> HolidayChange {
        switch days {
        case ..<2: .offLater0to1
        case 2...3: .offLater2to3
        case 4...7: .offLater4to7
        case 8...14: .offLater8to14
        default: .offLater15plus
        }
    }
}

/// What the person said on the first-open banner, if anything.
enum HolidayBannerAnswer: String {
    case kept, turnedOff, ignored
}

/// The holiday decorations' state: which part of the season it is, whether they're on, the
/// first-open banner and the last-day notice. The app reads this and shows the module's views
/// when `isFestive`; nothing here touches the app's own settings.
///
/// Everything is kept per season (`s2026.` keys) in the module's own defaults suite, so a
/// choice made this December doesn't carry into the next one and the app's own preferences
/// never see any of it.
@MainActor
public final class Holiday: ObservableObject {
    /// `MACRAZER_HOLIDAY_DATE=2026-12-25` in the environment previews that day (at its local
    /// time of day now), for checking the decorations outside December.
    /// A preview keeps its own scratch storage, so it never answers the banner or adds to the
    /// score for real.
    public static let shared: Holiday = {
        let clock = previewClock()
        guard clock != nil || scratchStorage else { return Holiday() }
        let suite = "MacRazer.holiday-preview"
        UserDefaults().removePersistentDomain(forName: suite)
        return Holiday(defaults: UserDefaults(suiteName: suite) ?? .standard, now: clock ?? Date.init)
    }()

    private static var scratchStorage = false

    /// For the app's `render-*` commands: whatever a render shows, it keeps to scratch storage,
    /// so rendering in December never answers the banner for real. Call before anything
    /// touches `shared`.
    public static func useScratchStorage() { scratchStorage = true }

    static func previewClock(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> (() -> Date)? {
        guard let text = environment["MACRAZER_HOLIDAY_DATE"] else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let day = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        let offset = day.timeIntervalSince(Calendar.current.startOfDay(for: Date()))
        return { Date().addingTimeInterval(offset) }
    }

    /// Today's phase, or nil outside the season.
    @Published public private(set) var phase: HolidayPhase?
    /// The decorations are showing: in season, switched on, and not turned off remotely.
    @Published public private(set) var isFestive = false
    /// The Settings switch: on by default each season.
    @Published public private(set) var decorationsOn = true
    /// The first-open banner should show, once the popover has nothing more important to say.
    @Published public private(set) var bannerPending = false
    /// The last-day notice should show.
    @Published public private(set) var endingNoticePending = false
    /// The Worker hasn't switched the decorations off for everyone.
    @Published public private(set) var remoteAllowed = true
    /// Reduce Motion or Low Power Mode: decorations stay, but nothing moves and no one peeks.
    @Published public private(set) var stillMode = false
    /// The start of today. Changes at midnight, so views showing the countdown redraw even
    /// on the advent days, when the phase stays the same.
    @Published public private(set) var today = Date.distantPast
    /// The banner is in the popover's layout. It only counts as seen when the popover opens
    /// with it there: the app builds the popover ahead of time, before anyone looks.
    private var bannerInView = false
    /// The popover is open on screen with the decorations on, as its delegate tells it: not
    /// just built. Stays false off season, so it never redraws the app's popover then.
    @Published public private(set) var popoverOpen = false
    private var popoverOnScreen = false
    /// This opening of the popover already counted a showing of the banner.
    private var bannerCountedThisOpening = false
    /// The season whose storage is current, published so the game reloads its score when a
    /// long-running app crosses into a new season.
    @Published public private(set) var storageSeason: Int?

    let defaults: UserDefaults
    private let calendar: Calendar
    let now: () -> Date
    /// Reduce Motion or Low Power Mode, asked of the system. Tests pass their own.
    private let stillness: () -> Bool
    private var midnightTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// How many times the banner may show without an answer before it settles as kept.
    static let bannerShowsBeforeIgnored = 3

    public init(defaults: UserDefaults = UserDefaults(suiteName: "MacRazer.holiday") ?? .standard,
                calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
                watchSystem: Bool = true, stillness: (() -> Bool)? = nil) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        self.stillness = stillness ?? { Holiday.systemWantsStillness() }
        refresh()
        if watchSystem { watch() }
    }

    /// The season the current day belongs to, for keys and for the Worker.
    public var seasonYear: Int? { HolidaySeason.year(of: now(), calendar: calendar) }

    /// The season whose storage is current: the season itself, and for the rest of January
    /// the one that just ended, so changes made on the last day can still be reported.
    var storageYear: Int? {
        if let seasonYear { return seasonYear }
        let parts = calendar.dateComponents([.year, .month], from: now())
        guard parts.month == 1, let year = parts.year else { return nil }
        return year - 1
    }

    /// The Settings row: shown all season, even with the decorations off, so they can come back.
    public var showsSettingsRow: Bool { phase != nil && remoteAllowed }

    /// Where the presents are today, while the decorations are on.
    public var presentsStage: HolidayPresentsStage? {
        guard isFestive else { return nil }
        return HolidaySeason.presentsStage(of: now(), calendar: calendar)
    }

    /// "24 sleeps until Christmas", or the phase's own line.
    public var headline: String? {
        guard let phase else { return nil }
        switch phase {
        case .advent:
            let n = HolidaySeason.sleepsUntilChristmas(from: now(), calendar: calendar) ?? 0
            return n == 1 ? "1 sleep until Christmas" : "\(n) sleeps until Christmas"
        case .christmasEve: return "Christmas Eve. Presents arrive tomorrow"
        case .christmasDay: return "Merry Christmas"
        case .afterChristmas: return "Season's greetings"
        case .newYearsDay: return "Happy New Year"
        case .windDown: return "Decorations come down after Jan 6"
        case .lastDay: return "Last day of the holidays"
        }
    }

    // MARK: Choices

    /// "Keep it" on the banner.
    public func keep() {
        answerBanner(.kept, change: .kept)
    }

    /// "Turn off decorations" on the banner.
    public func turnOffFromBanner() {
        answerBanner(.turnedOff, change: .offAtBanner)
        setStored(false, "decorationsOn")
        refresh()
    }

    /// The Settings switch.
    public func setDecorations(on: Bool) {
        guard phase != nil, on != decorationsOn else { return }
        if bannerAnswer == nil {
            // The switch answers the banner too: it was a choice, made somewhere else.
            answerBanner(on ? .kept : .turnedOff, change: on ? .kept : .offAtBanner)
        } else if on {
            record(.onLater)
            setStored(now().timeIntervalSince1970, "keptSince")
        } else {
            let since = stored(Double.self, "keptSince").map(Date.init(timeIntervalSince1970:)) ?? now()
            let days = calendar.dateComponents([.day], from: since, to: now()).day ?? 0
            record(.offLater(afterDays: days))
        }
        setStored(on, "decorationsOn")
        refresh()
    }

    /// The banner joined or left the popover's layout.
    func setBannerInView(_ inView: Bool) {
        bannerInView = inView
        countBannerIfSeen()
    }

    /// The popover opened or closed.
    func setPopoverOpen(_ open: Bool) {
        popoverOnScreen = open
        if !open { bannerCountedThisOpening = false }
        publishPopoverOpen()
        countBannerIfSeen()
    }

    /// One showing per opening, once the popover is open and the banner is in it, whichever
    /// of the two SwiftUI and AppKit report first.
    private func countBannerIfSeen() {
        guard popoverOnScreen, bannerInView, !bannerCountedThisOpening else { return }
        bannerCountedThisOpening = true
        bannerShown()
    }

    private func publishPopoverOpen() {
        let open = popoverOnScreen && isFestive
        if popoverOpen != open { popoverOpen = open }
    }

    /// The banner was on screen in an open popover. After three showings with no answer it
    /// settles as kept, so it doesn't keep asking.
    func bannerShown() {
        guard bannerPending else { return }
        let shows = (stored(Int.self, "bannerShows") ?? 0) + 1
        setStored(shows, "bannerShows")
        if stored(Double.self, "keptSince") == nil { setStored(now().timeIntervalSince1970, "keptSince") }
        if shows >= Self.bannerShowsBeforeIgnored { answerBanner(.ignored, change: .bannerIgnored) }
    }

    /// The last-day notice's close button.
    public func dismissEndingNotice() {
        setStored(true, "endingDismissed")
        refresh()
    }

    /// The Worker's answer on whether the decorations may show this season.
    public func setRemoteAllowed(_ allowed: Bool) {
        guard allowed != remoteAllowed else { return }
        setStored(allowed, "remoteAllowed")
        refresh()
    }

    // MARK: Stats

    /// Changes not reported yet, oldest first.
    public var pendingChanges: [HolidayChange] {
        (stored([String].self, "pendingChanges") ?? []).compactMap(HolidayChange.init(rawValue:))
    }

    /// The count carrying these changes reached the Worker.
    public func changesSent(_ sent: [HolidayChange]) {
        var left = stored([String].self, "pendingChanges") ?? []
        for change in sent {
            if let i = left.firstIndex(of: change.rawValue) { left.remove(at: i) }
        }
        setStored(left, "pendingChanges")
    }

    /// The day's state for the count: on, off, or not answered yet.
    public var stateForCount: String {
        if !decorationsOn { return "off" }
        return bannerAnswer == nil ? "undecided" : "on"
    }

    func record(_ change: HolidayChange) {
        guard seasonYear != nil else { return }
        setStored((stored([String].self, "pendingChanges") ?? []) + [change.rawValue], "pendingChanges")
    }

    /// Records the first catch of the season, once.
    func recordPlayedOnce() {
        guard stored(Bool.self, "played") != true else { return }
        setStored(true, "played")
        record(.played)
    }

    // MARK: State

    var bannerAnswer: HolidayBannerAnswer? {
        stored(String.self, "bannerAnswer").flatMap(HolidayBannerAnswer.init(rawValue:))
    }

    private func answerBanner(_ answer: HolidayBannerAnswer, change: HolidayChange) {
        guard phase != nil, bannerAnswer == nil else { return }
        setStored(answer.rawValue, "bannerAnswer")
        // Ignored means kept since the first showing, which `bannerShown` already noted.
        if answer != .ignored || stored(Double.self, "keptSince") == nil {
            setStored(now().timeIntervalSince1970, "keptSince")
        }
        record(change)
        refresh()
    }

    /// Works out everything published from the date and what's stored. Cheap; called at
    /// midnight, on wake, and after every choice.
    public func refresh() {
        let phase = HolidaySeason.phase(of: now(), calendar: calendar)
        let on = stored(Bool.self, "decorationsOn") ?? true
        let allowed = stored(Bool.self, "remoteAllowed") ?? true
        let festive = phase != nil && on && allowed
        if self.phase != phase { self.phase = phase }
        if decorationsOn != on { decorationsOn = on }
        if remoteAllowed != allowed { remoteAllowed = allowed }
        if isFestive != festive { isFestive = festive }
        let banner = festive && bannerAnswer == nil
        if bannerPending != banner { bannerPending = banner }
        let ending = festive && phase == .lastDay && stored(Bool.self, "endingDismissed") != true
        if endingNoticePending != ending { endingNoticePending = ending }
        let still = stillness()
        if stillMode != still { stillMode = still }
        let day = calendar.startOfDay(for: now())
        if today != day { today = day }
        publishPopoverOpen()
        let season = storageYear
        if storageSeason != season { storageSeason = season }
    }

    static func systemWantsStillness() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled || ReduceMotion.isOn
    }

    private func watch() {
        scheduleMidnight()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(ReduceMotion.observe { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(ReduceMotion.observeWake { [weak self] in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.scheduleMidnight()
            }
        })
    }

    /// A timer to the next local midnight, so the phase changes on time in an app that runs
    /// for weeks. A minute's slack is fine; the wake observer covers a Mac asleep at midnight.
    private func scheduleMidnight() {
        midnightTimer?.invalidate()
        let fire = HolidaySeason.nextMidnight(after: now(), calendar: calendar).addingTimeInterval(1)
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.scheduleMidnight()
            }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    // MARK: Storage

    private func key(_ name: String) -> String { "s\(storageYear ?? 0).\(name)" }

    func stored<T>(_ type: T.Type, _ name: String) -> T? { defaults.object(forKey: key(name)) as? T }

    func setStored(_ value: Any, _ name: String) { defaults.set(value, forKey: key(name)) }
}

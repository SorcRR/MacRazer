// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Where in the holiday season a day falls. The season runs from December 1 to January 6 in
/// the Mac's own time zone, so it starts and ends at local midnight wherever the person is.
public enum HolidayPhase: String, CaseIterable, Sendable {
    /// December 1 to 23: the countdown to Christmas.
    case advent
    /// December 24.
    case christmasEve
    /// December 25.
    case christmasDay
    /// December 26 to 31.
    case afterChristmas
    /// January 1.
    case newYearsDay
    /// January 2 to 5.
    case windDown
    /// January 6, the last day: a notice says the decorations come down tonight.
    case lastDay

    /// The star on the tree goes up on Christmas Day and stays until the end.
    public var hasStar: Bool {
        switch self {
        case .advent, .christmasEve: false
        default: true
        }
    }
}

/// The calendar side of the season: which phase a date is in and which season it belongs to.
/// Pure and time-zone explicit, so the tests can walk every day of the year in any zone.
public enum HolidaySeason {
    /// The phase of a date, or nil outside the season.
    public static func phase(of date: Date, calendar: Calendar = .current) -> HolidayPhase? {
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return nil }
        switch (month, day) {
        case (12, 1...23): return .advent
        case (12, 24): return .christmasEve
        case (12, 25): return .christmasDay
        case (12, 26...31): return .afterChristmas
        case (1, 1): return .newYearsDay
        case (1, 2...5): return .windDown
        case (1, 6): return .lastDay
        default: return nil
        }
    }

    /// The season a date belongs to, named by its December's year: January 2027 is still the
    /// 2026 season. Nil outside the season.
    public static func year(of date: Date, calendar: Calendar = .current) -> Int? {
        guard phase(of: date, calendar: calendar) != nil else { return nil }
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return nil }
        return month == 12 ? year : year - 1
    }

    /// Whole days left until December 25, counted in "sleeps": on December 24 it's 1. Nil
    /// from Christmas Day on and outside the season.
    public static func sleepsUntilChristmas(from date: Date, calendar: Calendar = .current) -> Int? {
        guard let phase = phase(of: date, calendar: calendar), phase == .advent || phase == .christmasEve,
              let year = calendar.dateComponents([.year], from: date).year,
              let christmas = calendar.date(from: DateComponents(year: year, month: 12, day: 25)) else { return nil }
        let today = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: today, to: christmas).day
    }

    /// The next local midnight after a date, when the phase can next change.
    public static func nextMidnight(after date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }
}

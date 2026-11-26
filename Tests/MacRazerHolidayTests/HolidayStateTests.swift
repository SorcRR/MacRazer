// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazerHoliday

@MainActor
final class HolidayStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var clock = Date()
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "HolidayStateTests.\(UUID().uuidString)")
    }

    private func at(_ y: Int, _ m: Int, _ d: Int) {
        clock = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func make() -> Holiday {
        Holiday(defaults: defaults, calendar: calendar, now: { [unowned self] in clock }, watchSystem: false)
    }

    func testOffSeasonNothingShows() {
        at(2026, 11, 30)
        let h = make()
        XCTAssertNil(h.phase)
        XCTAssertFalse(h.isFestive)
        XCTAssertFalse(h.bannerPending)
        XCTAssertFalse(h.showsSettingsRow)
    }

    func testOnByDefaultWithTheBannerOnDecemberFirst() {
        at(2026, 12, 1)
        let h = make()
        XCTAssertTrue(h.isFestive)
        XCTAssertTrue(h.bannerPending)
        XCTAssertEqual(h.stateForCount, "undecided")
        XCTAssertEqual(h.headline, "24 sleeps until Christmas")
    }

    func testKeepingRecordsItAndHidesTheBanner() {
        at(2026, 12, 2)
        let h = make()
        h.keep()
        XCTAssertFalse(h.bannerPending)
        XCTAssertTrue(h.isFestive)
        XCTAssertEqual(h.pendingChanges, [.kept])
        XCTAssertEqual(h.stateForCount, "on")
    }

    func testTurningOffAtTheBanner() {
        at(2026, 12, 2)
        let h = make()
        h.turnOffFromBanner()
        XCTAssertFalse(h.isFestive)
        XCTAssertTrue(h.showsSettingsRow, "The switch stays so they can come back")
        XCTAssertEqual(h.pendingChanges, [.offAtBanner])
        XCTAssertEqual(h.stateForCount, "off")
    }

    func testTurnedOffLaterCarriesHowLongItWasKept() {
        at(2026, 12, 1)
        let h = make()
        h.keep()
        at(2026, 12, 6)
        h.setDecorations(on: false)
        XCTAssertEqual(h.pendingChanges, [.kept, .offLater4to7])
        h.setDecorations(on: true)
        XCTAssertEqual(h.pendingChanges.last, .onLater)
    }

    func testBannerSettlesAsKeptAfterThreeShowings() {
        at(2026, 12, 3)
        let h = make()
        h.bannerShown(); h.bannerShown()
        XCTAssertTrue(h.bannerPending)
        h.bannerShown()
        XCTAssertFalse(h.bannerPending)
        XCTAssertTrue(h.isFestive)
        XCTAssertEqual(h.pendingChanges, [.bannerIgnored])
    }

    func testSentChangesAreRemoved() {
        at(2026, 12, 3)
        let h = make()
        h.keep()
        h.changesSent([.kept])
        XCTAssertEqual(h.pendingChanges, [])
    }

    func testRemoteSwitchTurnsItOffForTheSeason() {
        at(2026, 12, 3)
        let h = make()
        h.setRemoteAllowed(false)
        XCTAssertFalse(h.isFestive)
        XCTAssertFalse(h.showsSettingsRow)
        // Next season starts allowed again.
        at(2027, 12, 3)
        h.refresh()
        XCTAssertTrue(h.isFestive)
    }

    func testEachSeasonStartsOver() {
        at(2026, 12, 3)
        let h = make()
        h.turnOffFromBanner()
        at(2027, 12, 1)
        h.refresh()
        XCTAssertTrue(h.isFestive)
        XCTAssertTrue(h.bannerPending)
        XCTAssertEqual(h.seasonYear, 2027)
    }

    func testLastDayNotice() {
        at(2027, 1, 6)
        let h = make()
        h.keep()
        XCTAssertTrue(h.endingNoticePending)
        h.dismissEndingNotice()
        XCTAssertFalse(h.endingNoticePending)
        at(2027, 1, 7)
        h.refresh()
        XCTAssertFalse(h.isFestive)
        XCTAssertNil(h.phase)
    }

    func testPreviewDate() {
        let clock = Holiday.previewClock(["MACRAZER_HOLIDAY_DATE": "2026-12-25"])
        XCTAssertNotNil(clock)
        XCTAssertEqual(HolidaySeason.phase(of: clock!()), .christmasDay)
        XCTAssertNil(Holiday.previewClock(["MACRAZER_HOLIDAY_DATE": "soon"]))
        XCTAssertNil(Holiday.previewClock([:]))
    }

    func testBannerCountsOnlyWhenThePopoverOpensWithIt() {
        at(2026, 12, 3)
        let h = make()
        // The app builds the popover ahead of time: in the layout, but nobody has looked.
        h.setBannerInView(true)
        h.setPopoverOpen(true); h.setPopoverOpen(false)
        h.setPopoverOpen(true); h.setPopoverOpen(false)
        XCTAssertTrue(h.bannerPending)
        h.setBannerInView(false)
        h.setPopoverOpen(true)
        XCTAssertTrue(h.bannerPending, "Not counted while another notice took its place")
        h.setBannerInView(true)
        h.setPopoverOpen(true)
        XCTAssertFalse(h.bannerPending)
    }

    func testIgnoredBannerKeepsTheFirstShowingAsKeptSince() {
        at(2026, 12, 3)
        let h = make()
        h.bannerShown()
        at(2026, 12, 10)
        h.bannerShown(); h.bannerShown()
        XCTAssertFalse(h.bannerPending)
        h.setDecorations(on: false)
        XCTAssertEqual(h.pendingChanges, [.bannerIgnored, .offLater4to7])
    }

    func testTodayChangesAtMidnightDuringAdvent() {
        at(2026, 12, 3)
        let h = make()
        let first = h.today
        XCTAssertEqual(h.headline, "22 sleeps until Christmas")
        at(2026, 12, 4)
        h.refresh()
        XCTAssertNotEqual(h.today, first)
        XCTAssertEqual(h.headline, "21 sleeps until Christmas")
    }

    func testBannerCountsWhicheverArrivesFirst() {
        at(2026, 12, 3)
        let h = make()
        // AppKit says it opened before SwiftUI puts the banner back.
        for _ in 0..<3 {
            h.setPopoverOpen(true)
            h.setBannerInView(true)
            h.setBannerInView(false)
            h.setBannerInView(true)
            h.setPopoverOpen(false)
            h.setBannerInView(false)
        }
        XCTAssertFalse(h.bannerPending, "Three openings, three showings: no more, no fewer")
        XCTAssertEqual(h.pendingChanges, [.bannerIgnored])
    }

    func testPopoverOpenStaysFalseOffSeason() {
        at(2026, 7, 1)
        let h = make()
        h.setPopoverOpen(true)
        XCTAssertFalse(h.popoverOpen)
    }
}

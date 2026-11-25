// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The DPI button's driver mode on a mouse with private keys: when it is read and written
/// (`DpiDriverModeBook`), how one change goes (`BluetoothDevice.setDeviceMode`, driven with a
/// mouse made of closures), and what the page says when it fails. Nothing here talks to a
/// mouse: the mode is volatile and writing it changes how the real button behaves, so every
/// rule about when it is written is checked here instead.
final class DpiDriverModeTests: XCTestCase {
    private typealias Book = DpiDriverModeBook
    private let interval = DpiDriverModeBook.recheckInterval

    // MARK: When

    /// Not wanted and never set: nothing goes to the mouse, whatever happens.
    func testNothingIsSentWhileItIsNotWanted() {
        var book = Book()
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 0), .nothing)
        XCTAssertEqual(book.step(for: .wantChanged, now: 0), .nothing)
        book.connectionChanged()
        book.doubtful()
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 100), .nothing)
        XCTAssertEqual(book.state(lastError: nil), .off)
    }

    /// Wanted: engaged at once, from the change itself or the first read of the mouse after
    /// it, and then only checked again every `recheckInterval`, quietly.
    func testItIsEngagedAtOnceThenCheckedEveryInterval() {
        var book = Book()
        book.setWanted(true)
        XCTAssertEqual(book.step(for: .wantChanged, now: 10), .engage)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 10), .engage, "or at the first read")
        XCTAssertEqual(book.state(lastError: nil), .off, "not set up yet")
        book.engaged(at: 10)
        XCTAssertEqual(book.state(lastError: nil), .engaged)
        XCTAssertTrue(book.maybeSet)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 10 + interval - 1), .nothing, "every poll would be too often")
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 10 + interval), .recheck)
        book.engaged(at: 10 + interval)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 11 + interval), .nothing)
    }

    /// A new connection, or a wake, may have lost the mode: it is engaged again at once
    /// (`BluetoothDevice.setDeviceMode` reads first, so a mouse still in it isn't written). A
    /// wake keeps the connection, which may still hold driver mode, so quitting would still
    /// write normal mode back; a new connection starts in normal mode, so it has nothing to
    /// give back until it is engaged again.
    func testANewConnectionOrAWakeEngagesItAgain() {
        let changes: [(String, Bool, (inout Book) -> Void)] = [("connection", false, { $0.connectionChanged() }),
                                                               ("wake", true, { $0.doubtful() })]
        for (name, keepsMaybeSet, change) in changes {
            var book = Book()
            book.setWanted(true)
            book.engaged(at: 0)
            change(&book)
            XCTAssertEqual(book.step(for: .mouseAnswered, now: 1), .engage, name)
            XCTAssertEqual(book.state(lastError: nil), .off, name)
            XCTAssertEqual(book.maybeSet, keepsMaybeSet, name)
            book.engaged(at: 1)
            XCTAssertTrue(book.maybeSet, "\(name): once engaged again, quitting writes normal mode back")
        }
    }

    /// A failed change isn't retried at once: the poll tries again an interval later, at most
    /// `maxAttempts` times on one connection, then not until the next connection, wake or
    /// change of mind. The page says why meanwhile.
    func testAFailureIsRetriedSlowlyAndThenLeftAlone() {
        var book = Book()
        book.setWanted(true)
        var now: TimeInterval = 0
        for attempt in 1...Book.maxAttempts {
            XCTAssertEqual(book.step(for: .mouseAnswered, now: now), .engage, "attempt \(attempt)")
            book.failed(at: now)
            XCTAssertEqual(book.state(lastError: "No."), .unavailable("No."))
            XCTAssertEqual(book.step(for: .mouseAnswered, now: now + 1), .nothing, "not in a tight loop")
            XCTAssertEqual(book.step(for: .wantChanged, now: now + 1), .nothing)
            now += interval
        }
        XCTAssertEqual(book.step(for: .mouseAnswered, now: now + 1000), .nothing, "given up on this connection")

        var woke = book
        woke.doubtful()
        XCTAssertEqual(woke.step(for: .mouseAnswered, now: now), .engage, "a wake is a fresh chance")
        var reconnected = book
        reconnected.connectionChanged()
        XCTAssertEqual(reconnected.step(for: .mouseAnswered, now: now), .engage, "so is a new connection")
        var rechosen = book
        rechosen.setWanted(true)
        XCTAssertEqual(rechosen.step(for: .wantChanged, now: now), .engage, "and choosing the action again")
    }

    /// No longer wanted: normal mode is written back, but only where this run may have left
    /// driver mode, and once it reads back nothing more is sent.
    func testNormalModeIsRestoredOnlyWhereItMayHaveBeenSet() {
        var book = Book()
        book.setWanted(true)
        book.setWanted(false)
        XCTAssertEqual(book.step(for: .wantChanged, now: 0), .nothing, "never set: nothing to undo")

        book.setWanted(true)
        book.engaged(at: 0)
        book.setWanted(false)
        XCTAssertEqual(book.state(lastError: nil), .off)
        XCTAssertEqual(book.step(for: .wantChanged, now: 1), .restore)
        book.restored()
        XCTAssertFalse(book.maybeSet)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 100), .nothing)
    }

    /// A write that went out unanswered may still have landed, so it counts as set: an engage
    /// that failed after its write is undone like one that worked.
    func testAWriteThatMayHaveLandedIsUndoneToo() {
        var book = Book()
        book.setWanted(true)
        book.mayHaveSet()
        book.failed(at: 0)
        book.setWanted(false)
        XCTAssertEqual(book.step(for: .wantChanged, now: 1), .restore)
    }

    /// A restore that fails is tried again by the poll, slowly, as an engage is.
    func testAFailedRestoreIsRetriedSlowly() {
        var book = Book()
        book.setWanted(true)
        book.engaged(at: 0)
        book.setWanted(false)
        book.failed(at: 5)
        XCTAssertTrue(book.maybeSet)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 6), .nothing)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 5 + interval), .restore)
    }

    /// A quiet check that goes unanswered waits a whole interval before the next, as an
    /// answered one does. Before, it went out again at every poll (every 4 s with the pointer
    /// in use) for as long as the mouse didn't answer it, each holding the device queue for up
    /// to the lenient read's timeout.
    func testAnUnansweredCheckWaitsAWholeIntervalToo() {
        var book = Book()
        book.setWanted(true)
        book.engaged(at: 0)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: interval), .recheck)
        book.recheckUnanswered(at: interval)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: interval + 4), .nothing, "not at the next poll")
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 2 * interval - 1), .nothing)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 2 * interval), .recheck)
        XCTAssertEqual(book.state(lastError: nil), .engaged, "still taken for engaged meanwhile")
        book.engaged(at: 2 * interval)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 2 * interval + 1), .nothing)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 3 * interval), .recheck, "an answer starts the interval over")

        book.recheckUnanswered(at: 3 * interval)
        book.connectionChanged()
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 3 * interval + 1), .engage,
                       "a new connection is engaged at once, whatever went unanswered on the last")
    }

    // MARK: As the mouse settles

    /// After a wake a real Cobra took driver mode, read it back, and dropped it again a few
    /// hundred milliseconds later as it finished starting; the poll only saw it 30 seconds
    /// on. So the first engage on a new connection or after a wake is checked again
    /// `firstSettlingCheckDelay` and `secondSettlingCheckDelay` later (one-shots at
    /// `nextEarlyCheck`), and only then does the poll's interval take over.
    func testTheFirstEngageOnANewConnectionOrAfterAWakeIsCheckedAgainAsTheMouseSettles() {
        let first = Book.firstSettlingCheckDelay, second = Book.secondSettlingCheckDelay
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 3)
        let changes: [(String, (inout Book) -> Void)] = [("connection", { $0.connectionChanged() }),
                                                         ("wake", { $0.doubtful() })]
        for (name, change) in changes {
            var book = Book()
            book.setWanted(true)
            change(&book)
            XCTAssertEqual(book.step(for: .mouseAnswered, now: 100), .engage, name)
            XCTAssertTrue(book.engaged(at: 100, wrote: true), "\(name): the settling checks start")
            XCTAssertEqual(book.nextEarlyCheck, 100 + first, name)
            XCTAssertEqual(book.step(for: .earlyCheck, now: 100 + first - 0.1), .nothing, name)
            XCTAssertEqual(book.step(for: .earlyCheck, now: 100 + first), .recheck, name)
            XCTAssertEqual(book.earlyCheckDue(at: 100 + first)?.reason, .settling, name)
            XCTAssertFalse(book.engaged(at: 100 + first), "\(name): still in driver mode, nothing more starts")
            XCTAssertEqual(book.nextEarlyCheck, 100 + second, name)
            XCTAssertEqual(book.step(for: .mouseAnswered, now: 100 + second), .recheck,
                           "\(name): or from the poll, if it comes first")
            book.engaged(at: 100 + second)
            XCTAssertNil(book.nextEarlyCheck, name)
            XCTAssertEqual(book.step(for: .earlyCheck, now: 100 + second + 1), .nothing, name)
            XCTAssertEqual(book.step(for: .mouseAnswered, now: 100 + second + interval - 1), .nothing,
                           "\(name): the poll's interval from the last one")
            XCTAssertEqual(book.step(for: .mouseAnswered, now: 100 + second + interval), .recheck, name)
        }
    }

    /// Only the engage after a new connection or a wake settles: a later one on the same
    /// connection, after a change of mind for instance, has no early checks. And an early check
    /// is only ever a check: it never engages, restores or looks for a leftover.
    func testOnlyAFreshEngageSettlesAndAnEarlyCheckOnlyEverChecks() {
        var book = Book()
        book.connectionChanged()
        book.setWanted(true)
        book.engaged(at: 0, wrote: true)
        book.engaged(at: 1)
        book.engaged(at: 3)
        book.setWanted(false)
        XCTAssertEqual(book.step(for: .earlyCheck, now: 4), .nothing, "never a restore")
        XCTAssertEqual(book.step(for: .wantChanged, now: 4), .restore)
        book.restored()
        book.setWanted(true)
        XCTAssertEqual(book.step(for: .earlyCheck, now: 5), .nothing, "never an engage")
        XCTAssertEqual(book.step(for: .wantChanged, now: 5), .engage)
        XCTAssertFalse(book.engaged(at: 5, wrote: true), "the connection has settled")
        XCTAssertNil(book.nextEarlyCheck)

        var leftover = Book()
        leftover.answered(at: 0)
        XCTAssertEqual(leftover.step(for: .earlyCheck, now: 100), .nothing, "never a leftover read")
        XCTAssertEqual(leftover.step(for: .mouseAnswered, now: 100), .checkLeftover)
    }

    /// The settling checks are called off when the connection changes, after a wake, when
    /// driver mode stops being wanted, and when a change fails (the poll's slow retries take
    /// over). A new connection or wake settles again from its own engage.
    func testTheSettlingChecksAreCalledOffWhenTheConnectionChangesOrItIsNoLongerWanted() {
        func settling() -> Book {
            var book = Book()
            book.connectionChanged()
            book.setWanted(true)
            book.engaged(at: 0, wrote: true)
            XCTAssertNotNil(book.nextEarlyCheck)
            return book
        }
        var reconnected = settling()
        reconnected.connectionChanged()
        XCTAssertNil(reconnected.nextEarlyCheck, "a new connection")
        XCTAssertEqual(reconnected.step(for: .earlyCheck, now: 1), .nothing)
        XCTAssertEqual(reconnected.step(for: .mouseAnswered, now: 1), .engage, "engaged afresh instead")
        XCTAssertTrue(reconnected.engaged(at: 1), "and settling again from there")
        XCTAssertEqual(reconnected.nextEarlyCheck, 1 + Book.firstSettlingCheckDelay)

        var woke = settling()
        woke.doubtful()
        XCTAssertNil(woke.nextEarlyCheck, "a wake")

        var cleared = settling()
        cleared.setWanted(false)
        XCTAssertNil(cleared.nextEarlyCheck, "no longer wanted")
        XCTAssertEqual(cleared.step(for: .earlyCheck, now: 1), .nothing)

        var failing = settling()
        failing.failed(at: 1)
        XCTAssertNil(failing.nextEarlyCheck, "a failed change")
    }

    /// A check that finds the mouse back in normal mode puts driver mode back, and the
    /// settling checks start over from that write, as the firmware may not be done. At most
    /// `maxSettlingRounds` rounds per connection or wake: after that a fall-back is still put
    /// back, and the poll's interval goes on. A fall-back the poll finds on a settled
    /// connection settles too.
    func testAFallBackSeenAtASettlingCheckIsPutBackAndTheChecksStartOver() {
        var book = Book()
        book.connectionChanged()
        book.setWanted(true)
        book.engaged(at: 0, wrote: true)
        XCTAssertEqual(book.settlingRounds, 1)
        var now = Book.firstSettlingCheckDelay
        for round in 2...Book.maxSettlingRounds {
            XCTAssertEqual(book.step(for: .earlyCheck, now: now), .recheck, "round \(round)")
            XCTAssertTrue(book.engaged(at: now, wrote: true), "round \(round): written again, and settling starts over")
            XCTAssertEqual(book.settlingRounds, round)
            XCTAssertEqual(book.earlyChecks, Book.settlingCheckDelays.map { Book.EarlyCheck(at: now + $0, reason: .settling) },
                           "round \(round): from the write, the last round's later check replaced")
            XCTAssertEqual(book.state(lastError: nil), .engaged)
            now += Book.firstSettlingCheckDelay
        }
        XCTAssertEqual(book.step(for: .earlyCheck, now: now), .recheck)
        XCTAssertFalse(book.engaged(at: now, wrote: true), "the rounds are used up: put back, nothing more starts")
        XCTAssertEqual(book.state(lastError: nil), .engaged)
        XCTAssertEqual(book.earlyChecks.count, 1, "only the last round's later check is left")

        var settled = Book()
        settled.setWanted(true)
        settled.engaged(at: 0)
        XCTAssertNil(settled.nextEarlyCheck, "not a fresh connection")
        XCTAssertEqual(settled.step(for: .mouseAnswered, now: interval), .recheck)
        XCTAssertTrue(settled.engaged(at: interval, wrote: true), "the poll found it gone")
        XCTAssertEqual(settled.nextEarlyCheck, interval + Book.firstSettlingCheckDelay)
    }

    /// A settling check has the limits of any check. One whose write fails counts against
    /// `maxAttempts` like any change, and the poll retries it slowly. One that goes unanswered
    /// changes nothing and isn't repeated, though the round's later check still goes.
    func testASettlingCheckKeepsTheLimitsOfAnyCheck() {
        var book = Book()
        book.connectionChanged()
        book.setWanted(true)
        book.engaged(at: 0, wrote: true)
        XCTAssertEqual(book.step(for: .earlyCheck, now: 1), .recheck)
        book.recheckUnanswered(at: 1)
        XCTAssertEqual(book.step(for: .earlyCheck, now: 1.5), .nothing, "not repeated")
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 2), .nothing, "nor from the poll")
        XCTAssertEqual(book.nextEarlyCheck, 3, "the round's later check still goes")
        XCTAssertEqual(book.step(for: .earlyCheck, now: 3), .recheck)
        book.recheckUnanswered(at: 3)
        XCTAssertNil(book.nextEarlyCheck)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 3 + interval - 1), .nothing, "then the poll's interval")
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 3 + interval), .recheck)

        var failing = Book()
        failing.connectionChanged()
        failing.setWanted(true)
        failing.engaged(at: 0, wrote: true)
        XCTAssertEqual(failing.step(for: .earlyCheck, now: 1), .recheck)
        failing.failed(at: 1)
        XCTAssertEqual(failing.failures, 1, "it counts against the retries")
        XCTAssertEqual(failing.step(for: .earlyCheck, now: 3), .nothing, "no early retry")
        XCTAssertEqual(failing.step(for: .mouseAnswered, now: 3), .nothing)
        XCTAssertEqual(failing.step(for: .mouseAnswered, now: 1 + interval), .engage, "the poll's, an interval later")
    }

    // MARK: The mouse's notifications

    /// While driver mode is engaged, a notification that the firmware restarted (power state,
    /// availability) or cycled DPI itself calls for a check at once; a heartbeat, the battery
    /// or an unknown code doesn't. At most one check a second: the mouse sends several together
    /// as it starts, and each comes from both of its HID devices.
    func testANoticeOfARestartCallsForACheckAtOnceAtMostOnceASecond() {
        var book = Book()
        book.setWanted(true)
        book.engaged(at: 0)
        for notice: MouseNotice in [.heartbeat, .battery, .other(0x7E)] {
            XCTAssertEqual(book.noticed(notice, at: 10), .irrelevant, notice.name)
        }
        XCTAssertNil(book.nextEarlyCheck)
        XCTAssertEqual(book.noticed(.powerState, at: 10), .check)
        XCTAssertEqual(book.earlyCheckDue(at: 10)?.reason, .notice(0x0C))
        XCTAssertEqual(book.step(for: .earlyCheck, now: 10), .recheck, "at once")
        XCTAssertEqual(book.noticed(.powerState, at: 10.01), .debounced, "its copy from the other device")
        XCTAssertEqual(book.noticed(.availability(0x03), at: 10.5), .debounced)
        book.engaged(at: 10.1)
        XCTAssertNil(book.nextEarlyCheck, "done")
        XCTAssertEqual(book.noticed(.availability(0x02), at: 11), .check, "a second on")
        XCTAssertEqual(book.earlyCheckDue(at: 11)?.reason, .notice(0x09))
        book.engaged(at: 11)
        XCTAssertEqual(book.noticed(.dpiChanged(x: 4800, y: 4800), at: 12), .check, "the firmware cycling DPI")
        XCTAssertEqual(book.step(for: .wantChanged, now: 12), .nothing, "only from its own occasion or the poll")
    }

    /// A notification calls for nothing while driver mode isn't taken for engaged: not
    /// wanted, not engaged yet, failed, or after a check that went unanswered (the poll's
    /// interval rules then, so an unanswered read isn't repeated at each notification).
    func testANoticeCallsForNothingUnlessItIsEngaged() {
        var book = Book()
        XCTAssertEqual(book.noticed(.powerState, at: 0), .notEngaged, "not wanted")
        book.setWanted(true)
        XCTAssertEqual(book.noticed(.powerState, at: 0), .notEngaged, "not engaged yet")
        book.failed(at: 0)
        XCTAssertEqual(book.noticed(.powerState, at: 1), .notEngaged, "failed")
        book.engaged(at: 2)
        book.recheckUnanswered(at: 40)
        XCTAssertEqual(book.noticed(.powerState, at: 41), .notEngaged, "the last check went unanswered")
        XCTAssertNil(book.nextEarlyCheck)
        book.engaged(at: 70)
        XCTAssertEqual(book.noticed(.powerState, at: 71), .check, "until one is answered")
    }

    /// MacRazer's own DPI changes (the software DPI cycle, a DPI set in the app) are told by
    /// time: a notification that the DPI changed within `ownDpiChangeWindow` of one, said as
    /// its write starts and again as it ends, either side, is that change and calls for
    /// nothing. Later, it is the firmware cycling DPI by itself. Only a DPI change is told apart
    /// this way: a restart counts whenever it comes.
    func testTheAppsOwnDpiChangeDoesntCallForACheck() {
        let window = Book.ownDpiChangeWindow
        var book = Book()
        book.setWanted(true)
        book.engaged(at: 0)
        book.ownDpiChange(at: 100)
        book.ownDpiChange(at: 100.3)
        XCTAssertEqual(book.noticed(.dpiChanged(x: 1200, y: 1200), at: 100.4), .ownDpiChange)
        XCTAssertEqual(book.noticed(.dpiChanged(x: 1200, y: 1200), at: 100.3 + window - 0.01), .ownDpiChange)
        XCTAssertEqual(book.noticed(.dpiChanged(x: nil, y: nil), at: 100.2), .ownDpiChange,
                       "handed on as the write was still going out")
        XCTAssertNil(book.nextEarlyCheck)
        XCTAssertEqual(book.noticed(.powerState, at: 100.5), .check, "a restart isn't the app's")
        book.engaged(at: 100.5)
        XCTAssertEqual(book.noticed(.dpiChanged(x: 1600, y: 1600), at: 100.3 + window + 0.01), .check,
                       "past the window: the firmware's")
    }

    // MARK: The trace from a real Cobra

    /// The sleep and wake a trace of a real Cobra HyperSpeed over Bluetooth recorded, replayed
    /// on the book with its times. Before, the reconnect got `00 00` from a restore left over
    /// by the disconnect, then driver mode was engaged and read back, the mouse dropped it by
    /// itself as it finished starting, and its DPI button cycled DPI in the firmware until the
    /// poll's check 30 seconds later. Now the disconnect leaves nothing to restore, and the
    /// drop is caught by the first settling check, a second after the engage, and put back.
    func testTheWakeFromTheCobraTraceIsPutBackWithinASecondWithoutAStrayRestore() {
        var book = Book()
        // Engaged and settled long before.
        book.connectionChanged()
        book.answered(at: 500)
        book.setWanted(true)
        book.engaged(at: 500, wrote: true)
        book.engaged(at: 501)
        book.engaged(at: 503)

        // 634.03, `05 05 09 02 01`: the mouse going to sleep. The check it calls for goes
        // unanswered, which changes nothing.
        XCTAssertEqual(book.noticed(.availability(0x02), at: 634.03), .check)
        XCTAssertEqual(book.step(for: .earlyCheck, now: 634.03), .recheck)
        book.recheckUnanswered(at: 634.03)
        // 634.47, its HID device goes, and with it the connection. 635.44, no longer wanted,
        // as the remapper sees the mouse go.
        XCTAssertFalse(book.connectionChanged(), "still wanted then: no restore to drop")
        book.setWanted(false)
        XCTAssertEqual(book.step(for: .wantChanged, now: 635.44), .nothing, "nothing to give back")
        // 637.41, the mouse back; 637.86, the first read on the new connection.
        book.connectionChanged()
        book.answered(at: 637.86)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 637.86), .nothing, "no `00 00` on the new connection")
        // 637.88, wanted again: read `00 00`, write `03 00`, read back `03 00`.
        book.setWanted(true)
        XCTAssertEqual(book.step(for: .wantChanged, now: 637.88), .engage)
        XCTAssertTrue(book.engaged(at: 637.94, wrote: true), "the settling checks start")
        // 638.27, `05 05 0c 00` and `05 05 31 d9 ...`: the mouse finishing its start. The check
        // they call for may still find driver mode.
        XCTAssertEqual(book.noticed(.powerState, at: 638.27), .check)
        XCTAssertEqual(book.noticed(.battery, at: 638.27), .irrelevant)
        XCTAssertEqual(book.noticed(.powerState, at: 638.28), .debounced, "the other device's copy")
        XCTAssertEqual(book.step(for: .earlyCheck, now: 638.27), .recheck)
        XCTAssertFalse(book.engaged(at: 638.27))
        // Then the firmware drops it. The first settling check finds normal mode, long before
        // the press at 642.70 that the firmware took as a DPI cycle, and puts driver mode back.
        let first = 637.94 + Book.firstSettlingCheckDelay
        XCTAssertEqual(book.nextEarlyCheck, first)
        XCTAssertLessThan(first, 642.70)
        XCTAssertEqual(book.step(for: .earlyCheck, now: first), .recheck)
        XCTAssertTrue(book.engaged(at: first, wrote: true), "put back, and settling starts over")
        for check in Book.settlingCheckDelays.map({ first + $0 }) {
            XCTAssertEqual(book.step(for: .earlyCheck, now: check), .recheck)
            XCTAssertFalse(book.engaged(at: check), "it holds now")
        }
        XCTAssertNil(book.nextEarlyCheck, "the poll's interval from here")

        // Had the firmware dropped it later still, its own DPI change at a press
        // (`05 05 02 12 c0 12 c0` at 642.70) calls for a check at once, not 25 seconds later.
        let later = first + Book.secondSettlingCheckDelay + 1
        XCTAssertEqual(book.noticed(.dpiChanged(x: 0x12C0, y: 0x12C0), at: later), .check)
        XCTAssertEqual(book.step(for: .earlyCheck, now: later), .recheck)
        book.engaged(at: later, wrote: true)
        // And MacRazer's own DPI cycle, at the next press, calls for nothing.
        book.ownDpiChange(at: later + 5)
        XCTAssertEqual(book.noticed(.dpiChanged(x: 0x0320, y: 0x0320), at: later + 5.2), .ownDpiChange)
    }

    // MARK: A driver mode left by an earlier run

    /// MacRazer crashed or was killed with the mouse in driver mode, and this run doesn't want
    /// it: the mode is read, once the connection has answered for `leftoverCheckDelay` (by
    /// then the remapper has said whether it wants it on this mouse), and only from the poll.
    func testALeftoverIsLookedForOnceTheWantHasSettled() {
        var book = Book()
        book.answered(at: 100)
        book.answered(at: 104)
        XCTAssertEqual(book.answeringSince, 100, "the first answer on the connection")
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 100), .nothing, "the first reads at launch come too early")
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 100 + Book.leftoverCheckDelay - 1), .nothing)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 100 + Book.leftoverCheckDelay), .checkLeftover)
        XCTAssertEqual(book.step(for: .wantChanged, now: 100 + Book.leftoverCheckDelay), .nothing, "only from the poll")
        XCTAssertEqual(book.state(lastError: nil), .off, "nothing to show for it")

        var never = Book()
        XCTAssertEqual(never.step(for: .mouseAnswered, now: 1000), .nothing, "a mouse that never answered")
        never.answered(at: 0)
        never.connectionChanged()
        never.answered(at: 1000)
        XCTAssertEqual(never.step(for: .mouseAnswered, now: 1005), .nothing, "the delay starts over on a new connection")
        XCTAssertEqual(never.step(for: .mouseAnswered, now: 1000 + Book.leftoverCheckDelay), .checkLeftover)
    }

    /// Normal mode is written back only when the read says driver mode. Normal mode, or a
    /// mode MacRazer doesn't know, is left alone, and either way the mode isn't read again
    /// this run: from then on only this run can put the mouse in driver mode (`maybeSet`).
    func testALeftoverIsRestoredOnlyWhenItReadsAsDriverModeAndLookedForOnce() {
        let late = Book.leftoverCheckDelay
        for mode: UInt16 in [0, 1, 2, 0x0300] {
            var book = Book()
            book.answered(at: 0)
            XCTAssertFalse(book.leftoverRead(mode), "mode \(mode) is left alone")
            XCTAssertFalse(book.maybeSet, "mode \(mode)")
            XCTAssertEqual(book.step(for: .mouseAnswered, now: late), .nothing, "mode \(mode): once a run")
            book.connectionChanged()
            book.answered(at: late)
            XCTAssertEqual(book.step(for: .mouseAnswered, now: 10 * late), .nothing, "mode \(mode): not per connection")
        }

        var book = Book()
        book.answered(at: 0)
        XCTAssertTrue(book.leftoverRead(BLEProtocol.DeviceMode.driver.value))
        XCTAssertTrue(book.maybeSet, "quitting would write normal mode back too")
        XCTAssertEqual(book.step(for: .mouseAnswered, now: late), .restore, "until it reads back, as any restore")
        book.restored()
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 2 * late), .nothing)
    }

    /// A leftover read that goes unanswered writes nothing, and is tried again slowly, at most
    /// `maxAttempts` times on one connection, as a change is.
    func testAnUnansweredLeftoverReadIsRetriedSlowlyAndThenLeftAlone() {
        var book = Book()
        book.answered(at: 0)
        var now = Book.leftoverCheckDelay
        for attempt in 1...Book.maxAttempts {
            XCTAssertEqual(book.step(for: .mouseAnswered, now: now), .checkLeftover, "attempt \(attempt)")
            book.failed(at: now)
            XCTAssertFalse(book.maybeSet, "nothing was written")
            XCTAssertEqual(book.step(for: .mouseAnswered, now: now + 4), .nothing, "not in a tight loop")
            now += interval
        }
        XCTAssertEqual(book.step(for: .mouseAnswered, now: now + 1000), .nothing, "given up on this connection")
        book.connectionChanged()
        book.answered(at: now)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: now + Book.leftoverCheckDelay), .checkLeftover,
                       "a new connection is a fresh chance")
    }

    /// A run that wants driver mode reads it as it engages, and one that set it undoes its own
    /// (`restore`): neither looks for a leftover. Nor does one that already wrote normal mode
    /// back and read it.
    func testNoLeftoverIsLookedForWhereThisRunKnowsTheMode() {
        let late = Book.leftoverCheckDelay
        var wanting = Book()
        wanting.answered(at: 0)
        wanting.setWanted(true)
        XCTAssertEqual(wanting.step(for: .mouseAnswered, now: late), .engage, "the engage reads first instead")
        wanting.engaged(at: late)
        wanting.setWanted(false)
        XCTAssertEqual(wanting.step(for: .mouseAnswered, now: late + 1), .restore)
        wanting.restored()
        XCTAssertEqual(wanting.step(for: .mouseAnswered, now: 10 * late), .nothing)

        var mayHaveSet = Book()
        mayHaveSet.answered(at: 0)
        mayHaveSet.setWanted(true)
        mayHaveSet.mayHaveSet()
        mayHaveSet.failed(at: 0)
        mayHaveSet.setWanted(false)
        XCTAssertEqual(mayHaveSet.step(for: .mouseAnswered, now: late), .restore, "its own write is undone, not read for")
    }

    /// Losing the connection forgets what was verified and what failed, and that the mode may
    /// have been set (it didn't outlast the connection), but not what is wanted.
    func testLosingTheConnectionKeepsWhatIsWanted() {
        var book = Book()
        book.setWanted(true)
        book.engaged(at: 0)
        XCTAssertFalse(book.connectionChanged(), "wanted: no restore was pending")
        XCTAssertTrue(book.wanted)
        XCTAssertFalse(book.maybeSet)
        XCTAssertNil(book.verifiedAt)
        XCTAssertEqual(book.failures, 0)
    }

    // MARK: A disconnect and the restore

    /// Before, a restore of normal mode left pending by a disconnect went to the next
    /// connection: on the real Cobra, "no longer wanted" came only because the mouse slept and
    /// its device went away, and the reconnect got `00 00` before driver mode was wanted again.
    /// Now the disconnect drops the restore: the mouse starts the next connection in normal
    /// mode anyway. Clearing the action while connected still restores at once.
    func testADisconnectDropsThePendingRestoreButAClearStillRestores() {
        var book = Book()
        book.connectionChanged()
        book.setWanted(true)
        book.engaged(at: 0)
        book.setWanted(false)
        XCTAssertEqual(book.step(for: .wantChanged, now: 1), .restore, "cleared while connected: restored")

        var gone = Book()
        gone.connectionChanged()
        gone.setWanted(true)
        gone.engaged(at: 0)
        gone.setWanted(false)
        XCTAssertTrue(gone.connectionChanged(), "the restore was pending, and is dropped")
        XCTAssertFalse(gone.maybeSet, "and quitting has nothing to give back")
        gone.answered(at: 10)
        XCTAssertEqual(gone.step(for: .mouseAnswered, now: 10), .nothing, "the next connection gets no write")
        XCTAssertEqual(gone.step(for: .wantChanged, now: 10), .nothing)
        XCTAssertFalse(gone.connectionChanged(), "dropped once")

        var failedFirst = Book()
        failedFirst.setWanted(true)
        failedFirst.engaged(at: 0)
        failedFirst.setWanted(false)
        failedFirst.failed(at: 1)
        XCTAssertTrue(failedFirst.connectionChanged(), "a restore that failed on the old connection is dropped too")
        failedFirst.answered(at: 100)
        XCTAssertEqual(failedFirst.step(for: .mouseAnswered, now: 101), .nothing)
    }

    /// The restore is dropped on the guess that the mouse lost driver mode with the
    /// connection. Should only MacRazer's own connection have been reopened, with the mouse
    /// still in driver mode, the once-a-run leftover read is armed again: it reads the mode once
    /// the new connection has answered for `leftoverCheckDelay`, and writes normal mode only
    /// where it finds driver mode. A wake keeps the restore pending instead: it is the same
    /// connection.
    func testADroppedRestoreLeavesALeftoverReadAndAWakeKeepsIt() {
        var book = Book()
        book.setWanted(true)
        book.engaged(at: 0)
        book.setWanted(false)
        book.connectionChanged()
        book.answered(at: 100)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 100 + Book.leftoverCheckDelay - 1), .nothing)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 100 + Book.leftoverCheckDelay), .checkLeftover,
                       "read, not written")
        XCTAssertFalse(book.leftoverRead(0), "normal mode, as expected: nothing written")

        var woke = Book()
        woke.setWanted(true)
        woke.engaged(at: 0)
        woke.setWanted(false)
        woke.failed(at: 1)
        woke.doubtful()
        XCTAssertTrue(woke.maybeSet)
        XCTAssertEqual(woke.step(for: .mouseAnswered, now: 2), .restore, "a wake is a fresh chance for the restore")
    }

    // MARK: How

    /// A mouse made of closures: the mode it reads, what it does with a write, and every
    /// read and write it got.
    private final class Mouse {
        var mode: UInt16 = 0
        var readFails = false
        var readBackFails = false
        var refusesWrites = false
        var ignoresWrites = false
        private(set) var reads = 0
        private(set) var writes: [BLEProtocol.DeviceMode] = []

        func read() throws -> UInt16 {
            reads += 1
            if readFails || (readBackFails && !writes.isEmpty) { throw HIDDevice.HIDError.timeout }
            return mode
        }

        func write(_ mode: BLEProtocol.DeviceMode) throws {
            writes.append(mode)
            if refusesWrites { throw HIDDevice.HIDError.commandFailed }
            if !ignoresWrites { self.mode = mode.value }
        }

        func set(_ mode: BLEProtocol.DeviceMode, readFirst: Bool = true) throws -> BluetoothDevice.DeviceModeChange {
            try BluetoothDevice.setDeviceMode(mode, readFirst: readFirst, read: read, write: write)
        }
    }

    /// A mouse already in driver mode is read and left alone; one in normal mode gets one
    /// write and a read back.
    func testDriverModeIsReadFirstAndWrittenOnlyWhenItIsntThere() throws {
        let already = Mouse()
        already.mode = 3
        XCTAssertEqual(try already.set(.driver), .alreadySet)
        XCTAssertEqual(already.writes, [])
        XCTAssertEqual(already.reads, 1)

        let normal = Mouse()
        XCTAssertEqual(try normal.set(.driver), .written)
        XCTAssertEqual(normal.writes, [.driver])
        XCTAssertEqual(normal.reads, 2, "the read before and the read back")
    }

    /// A read that fails before the write means nothing is written.
    func testNothingIsWrittenWhenTheFirstReadFails() {
        let mouse = Mouse()
        mouse.readFails = true
        XCTAssertThrowsError(try mouse.set(.driver)) { error in
            XCTAssertEqual(error as? BLEProtocol.DeviceModeError, .unreadable)
        }
        XCTAssertEqual(mouse.writes, [])
    }

    /// A refused write, or a read back that differs or fails, throws, and no second write
    /// follows.
    func testAWriteThatDoesntReadBackThrowsAndIsntRepeated() {
        let refusing = Mouse()
        refusing.refusesWrites = true
        XCTAssertThrowsError(try refusing.set(.driver)) { error in
            XCTAssertEqual(error as? BLEProtocol.DeviceModeError, .notTaken)
        }
        XCTAssertEqual(refusing.writes, [.driver])

        let ignoring = Mouse()
        ignoring.ignoresWrites = true
        XCTAssertThrowsError(try ignoring.set(.driver)) { error in
            XCTAssertEqual(error as? BLEProtocol.DeviceModeError, .notReadBack(0))
        }
        XCTAssertEqual(ignoring.writes, [.driver])

        let silent = Mouse()
        silent.readBackFails = true
        XCTAssertThrowsError(try silent.set(.driver)) { error in
            XCTAssertEqual(error as? BLEProtocol.DeviceModeError, .notReadBack(nil))
        }
        XCTAssertEqual(silent.writes, [.driver])
    }

    /// Normal mode goes back with a write first and a read back: writing it again is harmless,
    /// and quitting has little time.
    func testNormalModeIsWrittenThenReadBack() throws {
        let mouse = Mouse()
        mouse.mode = 3
        XCTAssertEqual(try mouse.set(.normal, readFirst: false), .written)
        XCTAssertEqual(mouse.writes, [.normal])
        XCTAssertEqual(mouse.reads, 1)
        XCTAssertEqual(mouse.mode, 0)
    }

    // MARK: What the page says

    /// Each failure is a plain sentence that says what the button does meanwhile, never an
    /// error's debug text.
    func testTheErrorsArePlainSentences() {
        let errors: [Error] = [
            BLEProtocol.DeviceModeError.unreadable, BLEProtocol.DeviceModeError.notTaken,
            BLEProtocol.DeviceModeError.notReadBack(0), BLEProtocol.DeviceModeError.notReadBack(nil),
            HIDDevice.HIDError.timeout, HIDDevice.HIDError.notFound,
        ]
        for error in errors {
            let text = MouseController.dpiDriverModeErrorText(error)
            XCTAssertTrue(text.hasSuffix("."), text)
            XCTAssertTrue(text.contains("DPI"), text)
            XCTAssertFalse(text.contains("\u{2014}"), text)
            XCTAssertFalse(text.contains("Error") || text.contains("0x") || text.contains("HID"), text)
        }
    }
}

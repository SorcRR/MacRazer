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
    /// (`BluetoothDevice.setDeviceMode` reads first, so a mouse still in it isn't written).
    func testANewConnectionOrAWakeEngagesItAgain() {
        let changes: [(String, (inout Book) -> Void)] = [("connection", { $0.connectionChanged() }),
                                                         ("wake", { $0.doubtful() })]
        for (name, change) in changes {
            var book = Book()
            book.setWanted(true)
            book.engaged(at: 0)
            change(&book)
            XCTAssertEqual(book.step(for: .mouseAnswered, now: 1), .engage, name)
            XCTAssertEqual(book.state(lastError: nil), .off, name)
            XCTAssertTrue(book.maybeSet, "\(name): quitting still writes normal mode back")
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

    /// Losing the connection forgets what was verified and what failed, but not what is
    /// wanted, nor that the mode may have been set.
    func testLosingTheConnectionKeepsWhatIsWanted() {
        var book = Book()
        book.setWanted(true)
        book.engaged(at: 0)
        book.connectionChanged()
        XCTAssertTrue(book.wanted)
        XCTAssertTrue(book.maybeSet)
        XCTAssertNil(book.verifiedAt)
        XCTAssertEqual(book.failures, 0)
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

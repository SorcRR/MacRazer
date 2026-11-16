// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The order `HIDDevice.findAnsweringLink` tries a silent mouse's interfaces and ids in.
final class LinkSearchTests: XCTestCase {
    private let answer = RazerReport(commandClass: 0x00, commandId: 0x81, dataSize: 0x02)
    private let ids = DeviceProbe.transactionCandidates(preferred: nil)

    func testHeard() {
        XCTAssertTrue(LinkSearch.heard(.success(answer)))
        XCTAssertTrue(LinkSearch.heard(.failure(HIDDevice.HIDError.commandFailed)), "refused, so heard")
        XCTAssertTrue(LinkSearch.heard(.failure(HIDDevice.HIDError.notSupported)))
        XCTAssertFalse(LinkSearch.heard(.failure(HIDDevice.HIDError.timeout)))
        XCTAssertFalse(LinkSearch.heard(.failure(HIDDevice.HIDError.badResponse)))
    }

    /// An older mouse on 0xFF: the pick's other ids come before any other interface, and the
    /// search stops at the first one heard.
    func testOtherIdOnThePickFirst() {
        var tried: [(Int, UInt8)] = []
        let found = LinkSearch.firstHeard(links: [0, 1], ids: ids, current: 0x1F, skipping: (0, 0x1F)) { link, id in
            tried.append((link, id))
            return id == 0xFF ? .success(self.answer) : .failure(HIDDevice.HIDError.timeout)
        }
        XCTAssertEqual(found?.link, 0)
        XCTAssertEqual(found?.id, 0xFF)
        XCTAssertEqual(tried.map(\.1), [0x3F, 0xFF], "0x1F was already tried, and nothing after the answer")
        XCTAssertTrue(tried.allSatisfy { $0.0 == 0 })
    }

    /// The pick hears nothing: another interface that answers on the usual id wins.
    func testAnotherInterface() {
        let found = LinkSearch.firstHeard(links: [0, 1], ids: ids, current: 0x1F) { link, id in
            link == 1 && id == 0x1F ? .success(self.answer) : .failure(HIDDevice.HIDError.timeout)
        }
        XCTAssertEqual(found?.link, 1)
        XCTAssertEqual(found?.id, 0x1F)
    }

    /// A refusal settles the id in use, but a new id needs a real answer: a dongle refuses
    /// on its own while its mouse sleeps.
    func testRefusalCountsOnlyOnTheCurrentId() {
        let refusesAll = { (_: Int, _: UInt8) -> Result<RazerReport, Error> in .failure(HIDDevice.HIDError.notSupported) }
        XCTAssertEqual(LinkSearch.firstHeard(links: [1], ids: ids, current: 0x1F, read: refusesAll)?.id, 0x1F)
        let refusesOthers = { (_: Int, id: UInt8) -> Result<RazerReport, Error> in
            id == 0x1F ? .failure(HIDDevice.HIDError.timeout) : .failure(HIDDevice.HIDError.notSupported)
        }
        XCTAssertNil(LinkSearch.firstHeard(links: [0, 1], ids: ids, current: 0x1F, read: refusesOthers))
    }

    func testNothingHeard() {
        var count = 0
        let found = LinkSearch.firstHeard(links: [0, 1], ids: ids, current: 0x1F) { _, _ in
            count += 1
            return .failure(HIDDevice.HIDError.timeout)
        }
        XCTAssertNil(found)
        XCTAssertEqual(count, 2 * ids.count, "every id on every interface")
    }

    /// A search that heard nothing waits a minute before the next reopen runs it again,
    /// twice as long after each further miss, up to ten minutes. One that answered never runs
    /// again on that plug-in.
    func testShouldSearch() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(LinkSearch.shouldSearch(after: nil, now: t0))
        XCTAssertFalse(LinkSearch.shouldSearch(after: .answered(interface: 7), now: t0))
        let first = LinkSearch.silent(after: nil, now: t0)
        XCTAssertEqual(first, .silent(since: t0, misses: 1))
        XCTAssertFalse(LinkSearch.shouldSearch(after: first, now: t0.addingTimeInterval(59)))
        XCTAssertTrue(LinkSearch.shouldSearch(after: first, now: t0.addingTimeInterval(60)))
        let second = LinkSearch.silent(after: first, now: t0)
        XCTAssertEqual(second, .silent(since: t0, misses: 2))
        XCTAssertFalse(LinkSearch.shouldSearch(after: second, now: t0.addingTimeInterval(119)))
        XCTAssertTrue(LinkSearch.shouldSearch(after: second, now: t0.addingTimeInterval(120)))
        XCTAssertEqual(LinkSearch.retryDelay(misses: 10), 600, "capped")
    }

    /// Over a cable, a refusal on another id is heard too: nothing but the mouse can refuse.
    func testRefusalOnAnotherIdOverACable() {
        let found = LinkSearch.firstHeard(links: [0], ids: ids, current: 0x1F, acceptsRefusal: true) { _, id in
            id == 0x3F ? .failure(HIDDevice.HIDError.notSupported) : .failure(HIDDevice.HIDError.timeout)
        }
        XCTAssertEqual(found?.id, 0x3F)
    }

    func testRedirect() {
        XCTAssertNil(LinkSearch.redirect(pick: 1, after: nil))
        XCTAssertNil(LinkSearch.redirect(pick: 1, after: .answered(interface: 1)))
        XCTAssertNil(LinkSearch.redirect(pick: 1, after: .silent(since: Date(), misses: 1)))
        XCTAssertEqual(LinkSearch.redirect(pick: 1, after: .answered(interface: 2)), 2)
    }

    /// A pick heard after a silent search is recorded as answered, so its later silence
    /// reads as sleep and no search runs.
    func testAfterFirstRead() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(LinkSearch.afterFirstRead(heard: true, pick: 1, before: nil, now: t0),
                       .use(record: .answered(interface: 1)))
        XCTAssertEqual(LinkSearch.afterFirstRead(heard: true, pick: 1, before: .silent(since: t0, misses: 3), now: t0),
                       .use(record: .answered(interface: 1)), "woke up after a silent search")
        XCTAssertEqual(LinkSearch.afterFirstRead(heard: true, pick: 1, before: .answered(interface: 1), now: t0),
                       .use(record: nil))
        XCTAssertEqual(LinkSearch.afterFirstRead(heard: false, pick: 1, before: .answered(interface: 1), now: t0), .quiet)
        XCTAssertEqual(LinkSearch.afterFirstRead(heard: false, pick: 1, before: nil, now: t0), .search)
        XCTAssertEqual(LinkSearch.afterFirstRead(heard: false, pick: 1, before: .silent(since: t0, misses: 1),
                                                 now: t0.addingTimeInterval(10)), .quiet)
    }

    func testAfterSearch() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var rechecked = 0
        // Nothing heard: silent, one more miss, nothing learned, no recheck.
        let none = LinkSearch.afterSearch(found: nil, current: 0x1F, before: .silent(since: t0, misses: 1), now: t0) {
            rechecked += 1; return false
        }
        XCTAssertEqual(none, .init(outcome: .silent(since: t0, misses: 2), learn: nil))
        // Another interface on the id in use: switch interface, learn nothing, no recheck.
        let otherLink = LinkSearch.afterSearch(found: (5, 0x1F), current: 0x1F, before: nil, now: t0) {
            rechecked += 1; return false
        }
        XCTAssertEqual(otherLink, .init(outcome: .answered(interface: 5), learn: nil))
        XCTAssertEqual(rechecked, 0)
        // A new id, and the id in use still unheard: learn it.
        let learned = LinkSearch.afterSearch(found: (1, 0x3F), current: 0x1F, before: nil, now: t0) {
            rechecked += 1; return false
        }
        XCTAssertEqual(learned, .init(outcome: .answered(interface: 1), learn: 0x3F))
        // A new id, but the id in use answers on the recheck: it was only slow once.
        let slow = LinkSearch.afterSearch(found: (1, 0x3F), current: 0x1F, before: nil, now: t0) {
            rechecked += 1; return true
        }
        XCTAssertEqual(slow, .init(outcome: .answered(interface: 1), learn: nil))
        XCTAssertEqual(rechecked, 2)
    }
}

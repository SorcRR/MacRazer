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
        let found = LinkSearch.firstHeard(links: [0, 1], ids: ids, skipping: (0, 0x1F)) { link, id in
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
        let found = LinkSearch.firstHeard(links: [0, 1], ids: ids) { link, id in
            link == 1 && id == 0x1F ? .success(self.answer) : .failure(HIDDevice.HIDError.timeout)
        }
        XCTAssertEqual(found?.link, 1)
        XCTAssertEqual(found?.id, 0x1F)
    }

    /// A refusal is heard, so it settles the id as an answer would.
    func testRefusalCounts() {
        let found = LinkSearch.firstHeard(links: [0], ids: ids) { _, id in
            id == 0x3F ? .failure(HIDDevice.HIDError.notSupported) : .failure(HIDDevice.HIDError.timeout)
        }
        XCTAssertEqual(found?.id, 0x3F)
    }

    func testNothingHeard() {
        var count = 0
        let found = LinkSearch.firstHeard(links: [0, 1], ids: ids) { _, _ in
            count += 1
            return .failure(HIDDevice.HIDError.timeout)
        }
        XCTAssertNil(found)
        XCTAssertEqual(count, 2 * ids.count, "every id on every interface")
    }
}

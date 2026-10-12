// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class ReportCommentTests: XCTestCase {
    func testEmojiAreCutByTheirBytes() {
        // Each emoji is four bytes: 10 bytes over means three emoji, not ten.
        let comment = String(repeating: "😀", count: 20)
        XCTAssertEqual(ReportComment.trimmed(comment, dropping: 10), String(repeating: "😀", count: 17))
    }

    func testEscapedCharactersCountAtTheirJSONSize() {
        // A quote is two bytes in the JSON (\"), so 10 bytes over is five quotes. Counting raw
        // bytes would have cut ten.
        let comment = String(repeating: "\"", count: 100)
        XCTAssertEqual(ReportComment.trimmed(comment, dropping: 10), String(repeating: "\"", count: 95))
    }

    func testWholeCharactersOnly() {
        let family = "👩‍👩‍👧‍👦" // seven scalars, one character
        XCTAssertEqual(ReportComment.trimmed("ab" + family, dropping: 1), "ab",
                       "never a half-built family emoji")
    }

    func testNothingLeftIsNil() {
        XCTAssertNil(ReportComment.trimmed("short", dropping: 100))
        XCTAssertEqual(ReportComment.trimmed("short", dropping: 0), "short")
    }
}

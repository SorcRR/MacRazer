// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import IOKit.hid
import XCTest
@testable import MacRazer

/// How a device report leaves the test window, and the checks on what the person typed.
final class DeviceReportOutputTests: XCTestCase {
    private func report(comment: String? = nil, email: String? = nil, name: String = "Razer Naga V3 Pro") -> DeviceReport {
        var r = DeviceReport(
            appVersion: "0.5.0", macOSVersion: "26.6.2",
            device: .init(vendorID: 0x1532, productID: 0x00C4, name: name, connection: .dongle,
                          interfaces: [], controlInterface: nil),
            registry: nil,
            identify: .init(outcome: .passed, data: .init(firmware: "v1.3", standardAttempts: [], lightingAttempts: [],
                                                          standardId: 0x3F, lightingId: 0x3F)),
            battery: .init(outcome: .passed), dpi: .init(outcome: .failed), polling: .init(outcome: .notSupported),
            lighting: .init(outcome: .skipped), buttons: .init(),
            verdict: nil, comment: comment, credit: "someone", replyEmail: email)
        r.verdict = r.currentVerdict()
        return r
    }

    private func body(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "body" }?.value ?? ""
    }

    func testTheReplyEmailNeverReachesAnythingPublic() {
        // A GitHub issue is public, and a copied report tends to be pasted somewhere that is.
        let r = report(email: "person@example.com")
        XCTAssertFalse(DeviceReportOutput.json(r, forPublic: true).contains("person@example.com"))
        XCTAssertFalse(body(DeviceReportOutput.githubIssue(r)).contains("person@example.com"))
        XCTAssertFalse(DeviceReportOutput.issueClipboard(r).contains("person@example.com"))
        XCTAssertTrue(DeviceReportOutput.json(r, forPublic: false).contains("person@example.com"),
                      "it is kept for the maintainer-only path")
    }

    func testTheIssueLinkCarriesTheSummaryAndTheClipboardTheReport() {
        let r = report(comment: "Side buttons feel great")
        let url = DeviceReportOutput.githubIssue(r)
        let text = body(url)
        XCTAssertTrue(text.contains("**Razer Naga V3 Pro**, product ID 0x00C4, firmware v1.3, over the dongle"))
        XCTAssertTrue(text.contains("Failed: DPI"))
        XCTAssertTrue(text.contains("> Side buttons feel great"))
        XCTAssertTrue(text.contains("on your clipboard"))
        XCTAssertFalse(text.contains("```json"), "the report itself never goes in the link")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/SorcRR/MacRazer/issues/new?"))
        let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "title" }?.value
        XCTAssertEqual(title, "New mouse: 2 of 3 passed: Razer Naga V3 Pro (0x00C4)")

        let clip = DeviceReportOutput.issueClipboard(r)
        XCTAssertTrue(clip.contains("```json\n{"))
        XCTAssertTrue(clip.contains("\"productID\" : 196"))
    }

    func testALongCommentStaysInTheReportButLeavesTheLink() {
        // 2000 characters that each escape to six: well past what a link can carry.
        let r = report(comment: String(repeating: "é", count: DeviceReportOutput.maxComment))
        let url = DeviceReportOutput.githubIssue(r)
        XCTAssertLessThanOrEqual(url.absoluteString.count, DeviceReportOutput.maxIssueURLLength)
        XCTAssertFalse(body(url).contains("éééé"))
        XCTAssertTrue(body(url).contains("Failed: DPI"), "the summary still goes")
        XCTAssertTrue(DeviceReportOutput.issueClipboard(r).contains(String(repeating: "é", count: 50)))
    }

    func testANormalReportIsSentWhole() {
        let r = report(comment: "fine")
        XCTAssertEqual(DeviceReportOutput.fitted(r), r)
    }

    func testAnOversizedReportShedsEvidenceThenCommentUntilItFits() {
        // The most each step can record, and a comment of 2000 many-byte characters.
        let exchange = RecordingChannel.Exchange(commandClass: 0x04, commandId: 0x85, transactionId: 0x3F, status: 0x02,
                                                 response: [1, 2, 3, 4, 5, 6, 7, 8], error: "x", milliseconds: 40)
        let many = Array(repeating: exchange, count: RecordingChannel.maxExchanges)
        var r = report(comment: String(repeating: "👩‍👩‍👧‍👦", count: DeviceReportOutput.maxComment), email: "a@b.co")
        r.identify.exchanges = many; r.battery.exchanges = many; r.dpi.exchanges = many
        r.polling.exchanges = many; r.lighting.exchanges = many
        XCTAssertGreaterThan(DeviceReportOutput.size(r), DeviceReportOutput.maxReportBytes)

        let fitted = DeviceReportOutput.fitted(r)
        XCTAssertLessThanOrEqual(DeviceReportOutput.size(fitted), DeviceReportOutput.maxReportBytes)
        XCTAssertEqual(fitted.exchangesDropped, ["lighting", "polling", "dpi", "battery", "identify"])
        XCTAssertEqual(fitted.identify.data, r.identify.data, "what each step found stays")
        XCTAssertEqual(fitted.verdict, r.verdict)
        XCTAssertEqual(fitted.replyEmail, "a@b.co")
        XCTAssertTrue(r.comment!.hasPrefix(fitted.comment ?? ""), "the comment loses its end, not its start")
    }

    func testEvidenceGoesOneStepAtATimeAndOnlyAsMuchAsNeeded() {
        let exchange = RecordingChannel.Exchange(commandClass: 0x04, commandId: 0x85, transactionId: 0x3F, status: 0x02,
                                                 response: [1, 2, 3, 4, 5, 6, 7, 8], error: nil, milliseconds: 40)
        var r = report(comment: "short")
        r.identify.exchanges = Array(repeating: exchange, count: 20)
        r.lighting.exchanges = Array(repeating: exchange, count: 20)
        let fitted = DeviceReportOutput.fitted(r, maxBytes: DeviceReportOutput.size(r) - 1)
        XCTAssertEqual(fitted.exchangesDropped, ["lighting"])
        XCTAssertEqual(fitted.identify.exchanges.count, 20)
        XCTAssertEqual(fitted.comment, "short")
    }

    func testEmailChecks() {
        for ok in ["", "  ", "a@b.co", "first.last+tag@sub.example.org"] {
            XCTAssertNil(DeviceReportOutput.emailProblem(ok), ok)
        }
        for bad in ["plainaddress", "@example.com", "a@b", "a@.com", "a@b.", "two@@example.com", "a b@example.com",
                    "a@example.com\nBcc: x@y.z", String(repeating: "a", count: 250) + "@x.com",
                    "a\tb@example.com", "a@example.com\r", "a\u{2028}@example.com", "\u{FEFF}a@example.com",
                    "a\u{7}@example.com"] {
            XCTAssertNotNil(DeviceReportOutput.emailProblem(bad), bad)
        }
    }

    func testFreeTextIsTrimmedCappedAndEmptyBecomesNothing() {
        XCTAssertNil(DeviceReportOutput.cleaned("   \n ", max: 10, units: 40, singleLine: false))
        XCTAssertEqual(DeviceReportOutput.cleaned("  hi  ", max: 10, units: 40, singleLine: false), "hi")
        XCTAssertEqual(DeviceReportOutput.cleaned("abcdef", max: 3, units: 40, singleLine: false), "abc")
        XCTAssertEqual(DeviceReportOutput.cleaned("Jane\nDoe", max: 64, units: 256, singleLine: true), "Jane Doe",
                       "a credit is one line")
    }

    func testFreeTextLosesWhatTheWorkerRefuses() {
        // A pasted comment: Windows line endings, a tab, a bell, a stray line separator.
        XCTAssertEqual(DeviceReportOutput.cleaned("one\r\ntwo\rthree\tfour\u{7}\u{2028}five", max: 100, units: 100,
                                                  singleLine: false),
                       "one\ntwo\nthree\tfour\nfive")
        XCTAssertEqual(DeviceReportOutput.cleaned("Jane\tDoe\u{1B}", max: 64, units: 256, singleLine: true), "Jane Doe")
        XCTAssertEqual(DeviceReportOutput.cleaned("👩‍👩‍👧‍👦", max: 10, units: 100, singleLine: true), "👩‍👩‍👧‍👦",
                       "joiners inside an emoji are not control characters")
    }

    func testFreeTextFitsTheWorkersCountToo() {
        // 64 characters, but each is eleven UTF-16 units: the Worker would see 704.
        let family = String(repeating: "👩‍👩‍👧‍👦", count: DeviceReportOutput.maxCredit)
        let credit = DeviceReportOutput.cleaned(family, max: DeviceReportOutput.maxCredit,
                                                units: DeviceReportOutput.maxCreditUnits, singleLine: true)!
        XCTAssertLessThanOrEqual(credit.utf16.count, DeviceReportOutput.maxCreditUnits)
        XCTAssertEqual(credit.count, DeviceReportOutput.maxCreditUnits / 11, "cut between characters, never inside one")
    }

    // MARK: Button labels

    func testOnlyButtonsBeyondLeftAndRightKeysAndMediaCount() {
        XCTAssertNil(ButtonCapture.label(page: kHIDPage_Button, usage: 1, value: 1), "left click is the person pressing Next")
        XCTAssertNil(ButtonCapture.label(page: kHIDPage_Button, usage: 2, value: 1))
        XCTAssertEqual(ButtonCapture.label(page: kHIDPage_Button, usage: 4, value: 1), "09:04")
        XCTAssertNil(ButtonCapture.label(page: kHIDPage_Button, usage: 4, value: 0), "releases don't count")
        XCTAssertEqual(ButtonCapture.label(page: kHIDPage_KeyboardOrKeypad, usage: 0x1E, value: 1), "07:1e")
        XCTAssertNil(ButtonCapture.label(page: kHIDPage_KeyboardOrKeypad, usage: 0x01, value: 1), "error roll-over isn't a key")
        XCTAssertEqual(ButtonCapture.label(page: kHIDPage_Consumer, usage: 0xCD, value: 1), "0c:cd")
        XCTAssertNil(ButtonCapture.label(page: kHIDPage_GenericDesktop, usage: 0x30, value: 5), "movement")
    }

    func testFriendlyNames() {
        XCTAssertEqual(ButtonCapture.friendlyName("09:04"), "Button 4")
        XCTAssertEqual(ButtonCapture.friendlyName("07:1e"), "Key 1")
        XCTAssertEqual(ButtonCapture.friendlyName("07:27"), "Key 0")
        XCTAssertEqual(ButtonCapture.friendlyName("07:04"), "Key A")
        XCTAssertEqual(ButtonCapture.friendlyName("0c:cd"), "Media key")
    }
}

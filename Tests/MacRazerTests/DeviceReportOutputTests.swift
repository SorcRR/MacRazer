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

    private func body(_ issue: DeviceReportOutput.Issue) -> String {
        URLComponents(url: issue.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "body" }?.value ?? ""
    }

    func testTheReplyEmailNeverReachesAnythingPublic() {
        // A GitHub issue is public, and a copied report tends to be pasted somewhere that is.
        let r = report(email: "person@example.com")
        XCTAssertFalse(DeviceReportOutput.json(r, forPublic: true).contains("person@example.com"))
        XCTAssertFalse(body(DeviceReportOutput.githubIssue(r)).contains("person@example.com"))
        XCTAssertTrue(DeviceReportOutput.json(r, forPublic: false).contains("person@example.com"),
                      "it is kept for the maintainer-only path")
    }

    func testTheIssueCarriesASummaryAndTheFullReport() {
        let issue = DeviceReportOutput.githubIssue(report())
        XCTAssertFalse(issue.needsClipboard)
        let text = body(issue)
        XCTAssertTrue(text.contains("**Razer Naga V3 Pro**, product ID 0x00C4, firmware v1.3, over the dongle"))
        XCTAssertTrue(text.contains("Failed: DPI"))
        XCTAssertTrue(text.contains("```json"))
        XCTAssertTrue(issue.url.absoluteString.hasPrefix("https://github.com/SorcRR/MacRazer/issues/new?"))
        let title = URLComponents(url: issue.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "title" }?.value
        XCTAssertEqual(title, "New mouse: 2 of 3 passed: Razer Naga V3 Pro (0x00C4)")
    }

    func testAReportTooLongForALinkGoesOnTheClipboard() {
        // Every exchange of a long run, plus a full comment: more than a link can carry.
        var r = report(comment: String(repeating: "word ", count: 400))
        r.dpi.exchanges = Array(repeating: .init(commandClass: 0x04, commandId: 0x85, transactionId: 0x3F, status: 0x02,
                                                 response: [1, 2, 3, 4, 5, 6, 7, 8], error: nil, milliseconds: 40),
                                count: 100)
        let issue = DeviceReportOutput.githubIssue(r)
        XCTAssertTrue(issue.needsClipboard)
        XCTAssertLessThanOrEqual(issue.url.absoluteString.count, DeviceReportOutput.maxIssueURLLength)
        XCTAssertTrue(body(issue).contains("on your clipboard"))
        XCTAssertFalse(body(issue).contains("```json"))
    }

    func testEmailChecks() {
        for ok in ["", "  ", "a@b.co", "first.last+tag@sub.example.org"] {
            XCTAssertNil(DeviceReportOutput.emailProblem(ok), ok)
        }
        for bad in ["plainaddress", "@example.com", "a@b", "a@.com", "a@b.", "two@@example.com", "a b@example.com",
                    "a@example.com\nBcc: x@y.z", String(repeating: "a", count: 250) + "@x.com"] {
            XCTAssertNotNil(DeviceReportOutput.emailProblem(bad), bad)
        }
    }

    func testFreeTextIsTrimmedCappedAndEmptyBecomesNothing() {
        XCTAssertNil(DeviceReportOutput.cleaned("   \n ", max: 10, singleLine: false))
        XCTAssertEqual(DeviceReportOutput.cleaned("  hi  ", max: 10, singleLine: false), "hi")
        XCTAssertEqual(DeviceReportOutput.cleaned("abcdef", max: 3, singleLine: false), "abc")
        XCTAssertEqual(DeviceReportOutput.cleaned("Jane\nDoe", max: 64, singleLine: true), "Jane Doe",
                       "a credit is one line")
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

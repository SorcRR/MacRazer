// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

@MainActor
final class IssueReportTests: XCTestCase {
    private let endpoint = URL(string: "https://example.com/v1/issue-report")!
    private static let details = IssueReport.Details(appVersion: "0.8.0", macOS: "26.1", mice: [
        .init(name: "Razer Basilisk V3 Pro", productID: 0x00AB, link: "dongle", supported: true),
        .init(name: "Razer Viper Mini", productID: 0x008A, link: "wired", supported: false),
    ])

    private func model(status: Int = 200, sent: SentBox = SentBox()) -> IssueReportModel {
        IssueReportModel(endpoint: endpoint, details: { Self.details }, transport: { request in
            sent.requests.append(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }

    final class SentBox: @unchecked Sendable { var requests: [URLRequest] = [] }

    // MARK: The Worker's fixture

    static func fullReport() -> IssueReport {
        IssueReport(description: "The battery reads 0% after sleep.\n\tUntil I unplug the dongle.",
                    name: "Sam", replyEmail: "person@example.com", details: details)
    }

    private static var fixture: URL { WorkerFixtures.url("issue-report.json") }

    /// The Worker's tests check it accepts this file. Run with UPDATE_WORKER_FIXTURE=1 to
    /// rewrite it after changing the report.
    func testTheWorkerGetsEveryField() throws {
        let json = String(decoding: IssueReportOutput.json(Self.fullReport(), pretty: true), as: UTF8.self) + "\n"
        if ProcessInfo.processInfo.environment["UPDATE_WORKER_FIXTURE"] == "1" {
            try json.write(to: Self.fixture, atomically: true, encoding: .utf8)
        }
        func parsed(_ data: Data) throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }
        XCTAssertEqual(try parsed(Data(contentsOf: Self.fixture)), try parsed(Data(json.utf8)), """
            The issue report's format changed. Rewrite the fixture with UPDATE_WORKER_FIXTURE=1 swift test \
            --filter IssueReportTests, update src/issue.ts in SorcRR/macrazer-worker to match, and run its tests.
            """)
    }

    // MARK: Sending

    func testSendNeedsADescriptionAndAGoodEmail() {
        let m = model()
        XCTAssertTrue(m.sendDisabled, "nothing written yet")
        m.description = "  \n "
        XCTAssertTrue(m.sendDisabled, "blank isn't a description")
        m.description = "It crashes"
        XCTAssertFalse(m.sendDisabled)
        m.replyEmail = "not an email"
        XCTAssertTrue(m.sendDisabled)
        m.replyEmail = ""
        XCTAssertFalse(m.sendDisabled, "the email is optional")
    }

    func testSendPostsTheReportAndShowsTheThankYou() async throws {
        let sent = SentBox()
        let m = model(sent: sent)
        m.description = "It crashes"
        m.name = " Sam "
        m.replyEmail = "person@example.com"
        await m.send()
        XCTAssertEqual(m.sendState, .sent)
        XCTAssertEqual(sent.requests.count, 1)
        let request = try XCTUnwrap(sent.requests.first)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let report = try JSONDecoder().decode(IssueReport.self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(report, IssueReport(description: "It crashes", name: "Sam",
                                           replyEmail: "person@example.com", details: Self.details))

        await m.send()
        XCTAssertEqual(sent.requests.count, 1, "a sent report can't go twice")
    }

    func testUntickedDetailsAndEmptyFieldsAreLeftOut() async throws {
        let sent = SentBox()
        let m = model(sent: sent)
        m.description = "It crashes"
        m.includeDetails = false
        await m.send()
        let body = try XCTUnwrap(sent.requests.first?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "description"])
    }

    func testFailuresSayWhy() async {
        for (status, outcome) in [(429, DeviceReportSender.Outcome.tooMany), (400, .refused), (503, .unavailable)] {
            let m = model(status: status)
            m.description = "It crashes"
            await m.send()
            XCTAssertEqual(m.sendState, .failed(outcome))
            XCTAssertFalse(m.sendDisabled, "a failed send can be tried again")
        }
    }

    func testReopeningAfterSendingStartsFreshButADraftIsKept() async {
        let m = model()
        m.description = "Draft"
        m.windowWillShow()
        XCTAssertEqual(m.description, "Draft", "closed by mistake: nothing lost")
        m.name = "Sam"
        m.includeDetails = false
        // Sent after the window closed: still fresh on the next open.
        await m.send()
        m.windowWillShow()
        XCTAssertEqual(m.description, "")
        XCTAssertEqual(m.name, "")
        XCTAssertTrue(m.includeDetails)
        XCTAssertEqual(m.sendState, .idle)
    }

    func testWithoutTheWorkerOnlyGitHubIsOffered() {
        let m = IssueReportModel(endpoint: nil, details: { Self.details })
        m.description = "It crashes"
        XCTAssertFalse(m.canSend)
    }

    func testEveryFailureOffersTheContactAddress() {
        for outcome in [DeviceReportSender.Outcome.tooMany, .refused, .unavailable] {
            XCTAssertTrue(DeviceTestView.sendFailure(outcome).contains("Copy and email the report to contact@macrazer.com"))
            XCTAssertTrue(DeviceTestView.sendFailure(outcome, emailHint: "email us at contact@macrazer.com")
                .hasSuffix("or email us at contact@macrazer.com."))
        }
        XCTAssertTrue(DeviceTestView.sendFailure(.unavailable).contains("internet connection"))
        XCTAssertTrue(DeviceTestView.sendFailure(.tooMany).contains("too many from here today"))
    }

    func testTheEmailInsteadCarriesTheReportButNotTheNameOrAddress() throws {
        let m = model()
        m.description = "It crashes & burns\nafter sleep"
        m.name = "Sam"
        m.replyEmail = "person@example.com"
        let url = m.mailInstead
        XCTAssertEqual(url.scheme, "mailto")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "contact@macrazer.com")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["subject"], "MacRazer issue: It crashes & burns")
        XCTAssertTrue(query["body"]?.hasPrefix("It crashes & burns\nafter sleep\n\nMacRazer 0.8.0 on macOS 26.1") == true)
        XCTAssertFalse(url.absoluteString.contains("person"))
        XCTAssertFalse(url.absoluteString.contains("Sam"))
    }

    // MARK: Output

    func testTitleIsTheFirstLineCutToFit() {
        XCTAssertEqual(IssueReportOutput.title("\n  \nFirst\tline  \nsecond"), "First line")
        let long = String(repeating: "a", count: 100)
        let title = IssueReportOutput.title(long)
        XCTAssertEqual(title.count, IssueReportOutput.titleCharacters)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testAnOversizedDescriptionIsCutToFit() {
        var report = Self.fullReport()
        report.description = String(repeating: "👨‍👩‍👧‍👦", count: 2000)
        let fitted = IssueReportOutput.fitted(report)
        XCTAssertLessThanOrEqual(IssueReportOutput.json(fitted).count, DeviceReportOutput.maxReportBytes)
        XCTAssertFalse(fitted.description.isEmpty)
        XCTAssertTrue(report.description.hasPrefix(fitted.description))
    }

    func testTheGitHubIssueLeavesOutTheNameAndEmail() throws {
        let (url, needsPaste) = IssueReportOutput.githubIssue(Self.fullReport())
        XCTAssertFalse(needsPaste)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let body = try XCTUnwrap(query.first { $0.name == "body" }?.value)
        XCTAssertEqual(query.first { $0.name == "title" }?.value, "The battery reads 0% after sleep.")
        XCTAssertTrue(body.contains("Until I unplug the dongle."))
        XCTAssertTrue(body.contains("Razer Basilisk V3 Pro (0x00AB), over its dongle"))
        XCTAssertFalse(body.contains("person@example.com"))
        XCTAssertFalse(body.contains("Sam"))
    }

    func testALongDescriptionGoesOnTheClipboardInstead() throws {
        var report = Self.fullReport()
        report.description = "Title line\n" + String(repeating: "é ", count: 1999)
        let (url, needsPaste) = IssueReportOutput.githubIssue(report)
        XCTAssertTrue(needsPaste)
        XCTAssertLessThanOrEqual(url.absoluteString.count, DeviceReportOutput.maxIssueURLLength)
    }
}

@MainActor
final class IssueReportDetailsTests: XCTestCase {
    func testSendCarriesTheDetailsShownNotNewerOnes() async throws {
        var mice: [IssueReport.Mouse] = []
        let m = IssueReportModel(endpoint: URL(string: "https://example.com/v1/issue-report")!, details: {
            IssueReport.Details(appVersion: "0.8.0", macOS: "26.1", mice: mice)
        }, transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        m.windowWillShow()
        mice = [.init(name: "Razer Viper Mini", productID: 0x008A, link: "wired", supported: true)]
        m.description = "It crashes"
        XCTAssertEqual(m.finalReport().details?.mice, [], "plugged in after the window opened")
        m.windowWillShow()
        XCTAssertEqual(m.finalReport().details?.mice.count, 1, "the next open sees it")
    }

    func testControlCharactersAloneAreNoDescription() {
        let m = IssueReportModel(endpoint: nil, details: { .init(appVersion: "", macOS: "", mice: []) })
        m.description = "\u{07}\u{1B}"
        XCTAssertFalse(m.hasDescription, "cleaning leaves nothing to send")
    }

    func testTheThankYouNamesTheAddressThatWent() async {
        let m = IssueReportModel(endpoint: URL(string: "https://example.com/v1/issue-report")!,
                                 details: { .init(appVersion: "", macOS: "", mice: []) },
                                 transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        m.description = "It crashes"
        m.replyEmail = " person@example.com "
        await m.send()
        XCTAssertEqual(m.sentReplyEmail, "person@example.com")
        m.windowWillShow()
        XCTAssertNil(m.sentReplyEmail)
    }

    func testAByteOrderMarkIsNoDescription() {
        let m = IssueReportModel(endpoint: nil, details: { .init(appVersion: "", macOS: "", mice: []) })
        m.description = "\u{FEFF} \n"
        XCTAssertFalse(m.hasDescription)
    }

    func testEditingClearsTheClipboardNote() {
        let m = IssueReportModel(endpoint: nil, details: { .init(appVersion: "", macOS: "", mice: []) })
        m.description = "Title\n" + String(repeating: "é ", count: 1999)
        var copied: String?
        m.openURL = { _ in }
        m.copyToClipboard = { copied = $0 }
        m.openGitHubIssue()
        XCTAssertEqual(copied, m.finalReport().description)
        XCTAssertTrue(m.issueNeedsPaste)
        m.description = "Short"
        XCTAssertFalse(m.issueNeedsPaste)
    }
}

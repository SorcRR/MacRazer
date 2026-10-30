// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// Where the update check asks: the Worker first when the build has one, GitHub otherwise and
/// whenever the Worker fails. The Worker must never be the reason an update goes unseen.
@MainActor
final class UpdateCheckSourceTests: XCTestCase {
    private let worker = URL(string: "https://reports.example.org/v1/releases?app=0.6.0")!
    private let github = ProjectLinks.releasesAPI
    private let list = Data(#"[{"tag_name":"v0.6.0","body":"Notes","prerelease":false,"draft":false}]"#.utf8)

    private func answer(_ status: Int, _ data: Data) -> UpdateChecker.Fetch {
        { url in (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!) }
    }

    private func never(_ name: String) -> UpdateChecker.Fetch {
        { _ in XCTFail("asked \(name)"); throw URLError(.cancelled) }
    }

    func testAsksTheWorkerFirstAndGitHubNotAtAll() async throws {
        let releases = try await UpdateChecker.fetchReleases(worker: worker, github: github,
                                                             viaWorker: answer(200, list), viaGitHub: never("GitHub"))
        XCTAssertEqual(releases.map(\.version), ["0.6.0"])
    }

    func testFallsBackToGitHubWhenTheWorkerFailsInAnyWay() async throws {
        let failures: [UpdateChecker.Fetch] = [
            answer(502, Data(#"{"ok":false,"error":"upstream"}"#.utf8)),
            answer(200, Data("not json".utf8)),
            { _ in throw URLError(.timedOut) },
        ]
        for failure in failures {
            let releases = try await UpdateChecker.fetchReleases(worker: worker, github: github,
                                                                 viaWorker: failure, viaGitHub: answer(200, list))
            XCTAssertEqual(releases.map(\.version), ["0.6.0"])
        }
    }

    func testABuildWithoutAWorkerAsksGitHubOnly() async throws {
        let releases = try await UpdateChecker.fetchReleases(worker: nil, github: github,
                                                             viaWorker: never("the Worker"), viaGitHub: answer(200, list))
        XCTAssertEqual(releases.map(\.version), ["0.6.0"])
    }

    func testAGitHubErrorIsAFailedCheckNotAnEmptyList() async {
        do {
            _ = try await UpdateChecker.fetchReleases(worker: nil, github: github, viaWorker: never("the Worker"),
                                                      viaGitHub: answer(403, Data(#"{"message":"rate limit"}"#.utf8)))
            XCTFail("a 403 must throw, so the throttle isn't spent on it")
        } catch {}
    }

    func testTheWorkerURLNamesTheMiceAndNothingAboutTheMac() {
        let base = URL(string: "https://reports.example.org")
        let mice = [
            UsagePing.Mouse(pid: 0xDB, name: "Razer Cobra HyperSpeed", link: "dongle", supported: true),
            UsagePing.Mouse(pid: 0x99, name: "Basilisk V3 X.2 & co", link: "bluetooth", supported: false),
        ]
        let url = WorkerEndpoint.releases(appVersion: "0.6.1", mice: mice, base: base)!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.map(\.name), ["app", "mouse", "mouse"])
        XCTAssertEqual(items[1].value, "00db.dongle.1.Razer Cobra HyperSpeed")
        XCTAssertEqual(items[2].value, "0099.bluetooth.0.Basilisk V3 X.2 & co")
        // The & in a name is escaped, not a new parameter.
        XCTAssertTrue(url.absoluteString.contains("%26"))
        let five = Array(repeating: mice[0], count: 5)
        XCTAssertEqual(URLComponents(url: WorkerEndpoint.releases(appVersion: "0.6.1", mice: five, base: base)!,
                                     resolvingAgainstBaseURL: false)!.queryItems!.count, 5)
    }

    func testTheWorkerURLCarriesOnlyTheAppVersion() {
        let base = URL(string: "https://reports.example.org")
        XCTAssertEqual(WorkerEndpoint.releases(appVersion: "0.6.0", base: base)?.absoluteString,
                       "https://reports.example.org/v1/releases?app=0.6.0")
        XCTAssertEqual(WorkerEndpoint.releases(appVersion: nil, base: base)?.absoluteString,
                       "https://reports.example.org/v1/releases?app=dev")
        XCTAssertNil(WorkerEndpoint.releases(appVersion: "0.6.0", base: nil))
    }
}

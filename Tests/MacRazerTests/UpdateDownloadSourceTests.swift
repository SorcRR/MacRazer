// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// Where the updater downloads from: through the Worker first so the update is counted, and
/// straight from GitHub whenever that fails. Counting must never cost anyone an update.
@MainActor
final class UpdateDownloadSourceTests: XCTestCase {
    private let github = ProjectLinks.dmg(forVersion: "0.6.0", tag: "v0.6.0")
    private let counted = WorkerEndpoint.download(tag: "v0.6.0", base: URL(string: "https://reports.example.org"))
    private let file = URL(fileURLWithPath: "/tmp/MacRazer.dmg")

    func testTheCountedURLNamesOnlyTheRelease() {
        XCTAssertEqual(counted?.absoluteString, "https://reports.example.org/v1/download?via=update&tag=v0.6.0")
        XCTAssertNil(WorkerEndpoint.download(tag: "v0.6.0", base: nil))
    }

    func testDownloadsThroughTheWorkerWhenItWorks() async throws {
        var asked: [URL] = []
        let result = try await UpdateChecker.fetchDMG(github: github, counted: counted) { url in
            asked.append(url)
            return self.file
        }
        XCTAssertEqual(result, file)
        XCTAssertEqual(asked, [counted])
    }

    func testFallsBackToGitHubWhenTheWorkerPathFails() async throws {
        var asked: [URL] = []
        let result = try await UpdateChecker.fetchDMG(github: github, counted: counted) { url in
            asked.append(url)
            if url == self.counted { throw URLError(.badServerResponse) }
            return self.file
        }
        XCTAssertEqual(result, file)
        XCTAssertEqual(asked, [counted, github])
    }

    func testABuildWithoutAWorkerGoesStraightToGitHub() async throws {
        var asked: [URL] = []
        _ = try await UpdateChecker.fetchDMG(github: github, counted: nil) { url in
            asked.append(url)
            return self.file
        }
        XCTAssertEqual(asked, [github])
    }

    func testOfflineFailsOnceInsteadOfTryingGitHubToo() async {
        var asked: [URL] = []
        do {
            _ = try await UpdateChecker.fetchDMG(github: github, counted: counted) { url in
                asked.append(url)
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("offline must fail")
        } catch {}
        XCTAssertEqual(asked, [counted])
    }

    func testAGitHubFailureStillFailsTheUpdate() async {
        do {
            _ = try await UpdateChecker.fetchDMG(github: github, counted: counted) { _ in throw URLError(.notConnectedToInternet) }
            XCTFail("both paths failed, so the update must too")
        } catch {}
    }
}

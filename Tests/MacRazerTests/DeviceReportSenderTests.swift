// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// Send, and the contract between the app's report and the Worker in `worker/` that takes it.
final class DeviceReportSenderTests: XCTestCase {
    private let endpoint = URL(string: "https://reports.example/v1/device-report")!

    // MARK: The full report, shared with the Worker's tests

    /// Every field set, so the Worker's schema is checked against all of them. Add any new
    /// field here too; `testTheWorkerGetsEveryField` then fails until the fixture and the
    /// Worker's `validate.ts` catch up.
    static func fullReport() -> DeviceReport {
        let exchange = RecordingChannel.Exchange(commandClass: 0x04, commandId: 0x85, transactionId: 0x1F, status: 0x02,
                                                 response: [1, 0x19, 0, 0x19, 0, 0, 0, 0], error: nil, milliseconds: 38)
        let failed = RecordingChannel.Exchange(commandClass: 0x00, commandId: 0x81, transactionId: 0xFF, status: nil,
                                               response: [], error: "Device command timed out", milliseconds: 412)
        func attempts(_ answered: UInt8) -> [DeviceReport.TransactionResult] {
            DeviceProbe.knownTransactionIds.map {
                .init(id: $0, answered: $0 == answered, refused: false, groups: $0 == answered ? ["LOGO"] : [],
                      error: $0 == answered ? nil : "Device command timed out")
            }
        }
        var report = DeviceReport(
            appVersion: "0.6.0", macOSVersion: "26.6.2",
            device: .init(vendorID: 0x1532, productID: 0x00DB, name: "Razer Cobra HyperSpeed", connection: .dongle,
                          interfaces: [.init(productID: 0x00DB, product: "Razer Cobra HyperSpeed", usagePage: 1, usage: 2,
                                             maxFeatureReportSize: 90, maxInputReportSize: 8, transport: "USB")],
                          controlInterface: 0),
            registry: RazerDevices.info(pid: 0x00DB).map(DeviceReport.Registry.init),
            identify: .init(outcome: .passed,
                            data: .init(firmware: "v1.0", standardAttempts: attempts(0x1F), dpiAttempts: attempts(0x1F),
                                        lightingAttempts: attempts(0x1F), standardId: 0x1F, lightingId: 0x1F),
                            error: nil, exchanges: [exchange, failed]),
            battery: .init(outcome: .passed, data: .init(raw: 92, percent: 36, charging: false), exchanges: [exchange]),
            dpi: .init(outcome: .passed,
                       data: .init(original: 6400, test: 6350, readBack: 6350, restored: true,
                                   stages: [400, 800, 1600, 3200, 6400], maxProbe: 26000),
                       exchanges: [exchange]),
            polling: .init(outcome: .passed, data: .init(original: 500, test: 1000, readBack: 1000, restored: true)),
            lighting: .init(outcome: .passed,
                            data: .init(groups: ["LOGO": 10], dimShown: true, redShown: true, dimmed: true,
                                        turnedRed: true, restored: true)),
            // 0c:223 is AC Home: consumer usages run past two hex digits.
            buttons: .init(outcome: .passed, data: .init(seen: ["09:04", "09:05", "07:1e", "0c:223"]), error: "none"),
            verdict: nil, comment: "Works on my Mac.\nSide buttons too.", credit: "@someone",
            replyEmail: "person@example.com", exchangesDropped: ["lighting"])
        report.polling.error = "an example error"
        report.verdict = report.currentVerdict()
        return report
    }

    private static var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("worker/test/fixtures/full-report.json")
    }

    /// The Worker's tests check it accepts this file, and that it computes the same verdict.
    /// Run with UPDATE_WORKER_FIXTURE=1 to rewrite it after changing the report.
    func testTheWorkerGetsEveryField() throws {
        let json = DeviceReportOutput.json(Self.fullReport(), forPublic: false) + "\n"
        if ProcessInfo.processInfo.environment["UPDATE_WORKER_FIXTURE"] == "1" {
            try json.write(to: Self.fixture, atomically: true, encoding: .utf8)
        }
        // Compared as parsed JSON, not text: another Foundation (CI's macOS) may space or
        // escape the same report differently.
        func parsed(_ data: Data) throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }
        let onDisk = try parsed(Data(contentsOf: Self.fixture))
        XCTAssertEqual(onDisk, try parsed(Data(json.utf8)), """
            The report's format changed. Rewrite the fixture with UPDATE_WORKER_FIXTURE=1 swift test \
            --filter DeviceReportSenderTests, update worker/src/validate.ts to match, and run the Worker's tests.
            """)
    }

    // MARK: Sending

    func testStatusesMapToWhatThePersonIsTold() {
        XCTAssertEqual(DeviceReportSender.outcome(status: 200), .sent)
        XCTAssertEqual(DeviceReportSender.outcome(status: 429), .tooMany)
        for refused in [400, 404, 405, 413, 415] { XCTAssertEqual(DeviceReportSender.outcome(status: refused), .refused) }
        for down in [0, 500, 502, 503] { XCTAssertEqual(DeviceReportSender.outcome(status: down), .unavailable) }
    }

    func testTheRequestCarriesTheReplyEmailAsCompactJSON() throws {
        let request = DeviceReportSender.request(Self.fullReport(), to: endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 10)
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(DeviceReport.self, from: body)
        XCTAssertEqual(decoded.replyEmail, "person@example.com", "Send is the one way out that carries it")
        XCTAssertEqual(decoded, Self.fullReport())
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("\n  "), "compact, not pretty")
    }

    func testTheRequestAlwaysFitsTheWorkersCap() throws {
        var report = Self.fullReport()
        let many = Array(repeating: report.dpi.exchanges[0], count: RecordingChannel.maxExchanges)
        report.identify.exchanges = many; report.dpi.exchanges = many; report.battery.exchanges = many
        report.comment = String(repeating: "👩‍👩‍👧‍👦", count: 700)
        let body = try XCTUnwrap(DeviceReportSender.request(report, to: endpoint).httpBody)
        XCTAssertLessThanOrEqual(body.count, DeviceReportOutput.maxReportBytes)
    }

    func testSendReportsWhatCameBack() async {
        func answering(_ status: Int) -> DeviceReportSender.Transport {
            { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
        }
        let report = Self.fullReport()
        let sent = await DeviceReportSender.send(report, to: endpoint, transport: answering(200))
        XCTAssertEqual(sent, .sent)
        let limited = await DeviceReportSender.send(report, to: endpoint, transport: answering(429))
        XCTAssertEqual(limited, .tooMany)
        let offline = await DeviceReportSender.send(report, to: endpoint) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(offline, .unavailable)
    }

    /// The real thing, end to end: this app's request, a real URLSession, and the Worker in
    /// Cloudflare's runtime. Skipped unless MACRAZER_WORKER_URL points at one, such as
    /// `npx wrangler dev` in worker/ (http://127.0.0.1:8787/v1/device-report).
    func testSendReachesARunningWorker() async throws {
        guard let url = ProcessInfo.processInfo.environment["MACRAZER_WORKER_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("Set MACRAZER_WORKER_URL to a running Worker to run this.")
        }
        let outcome = await DeviceReportSender.send(Self.fullReport(), to: url)
        XCTAssertEqual(outcome, .sent)
    }

    // MARK: After sending

    func testTheThankYouSaysWhatTheReportMeans() {
        func verdict(_ known: Bool, _ outcomes: [DeviceReport.Outcome]) -> DeviceTestVerdict {
            DeviceTestVerdict.make(knownFullySupported: known, steps: zip(["Identify", "Battery", "DPI", "Polling rate", "Lighting"], outcomes).map { ($0, $1) })
        }
        let all = [DeviceReport.Outcome](repeating: .passed, count: 5)
        XCTAssertEqual(verdict(true, all).thankYou(firmware: "v1.0"),
                       "Your mouse is already fully supported, and your report confirms it on firmware v1.0. It helps keep the supported list accurate.")
        XCTAssertTrue(verdict(false, all).thankYou(firmware: nil).hasPrefix("Everything worked."))
        XCTAssertEqual(verdict(true, [.passed, .passed, .failed, .passed, .failed]).thankYou(firmware: nil),
                       "Your mouse should be fully supported, but DPI and Lighting didn't work. Your report shows us what to fix.")
        XCTAssertTrue(verdict(false, [.passed, .failed, .failed, .failed, .passed]).thankYou(firmware: nil)
            .hasPrefix("Battery, DPI and Polling rate didn't work"))
        XCTAssertTrue(verdict(true, [.passed, .skipped, .passed, .passed, .passed]).thankYou(firmware: nil)
            .hasPrefix("Some steps were skipped"), "a skipped step never reads as a confirmation")
    }
}

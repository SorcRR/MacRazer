// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// A trimmed `.ips` in the real two-document shape, modelled on the relaunch crash. It keeps
/// the fields that must never be sent, so the tests can check they aren't.
enum CrashFixture {
    static func ips(bundleID: String = CrashReportParser.bundleID, bugType: String = "309",
                    frames: Int = 5, asi: String? = nil) -> Data {
        let header: [String: Any] = [
            "app_name": "MacRazer", "app_version": "0.6.0", "build_version": "41",
            "bundleID": bundleID, "bug_type": bugType, "os_version": "macOS 26.6.2 (25G83)",
            "incident_id": "5E0C7B1A-8F43-4C2B-9D7E-1A2B3C4D5E6F", "timestamp": "2026-09-23 18:23:32.00 +0300",
        ]
        let top: [[String: Any]] = [
            ["imageOffset": 1000, "symbol": "_dispatch_assert_queue_fail", "symbolLocation": 120, "imageIndex": 1],
            ["imageOffset": 2000, "symbol": "swift_task_isCurrentExecutorImpl", "symbolLocation": 284, "imageIndex": 2],
            ["imageOffset": 3000, "symbol": "closure #1 in UpdateChecker.relaunch(at:)", "symbolLocation": 52, "imageIndex": 0],
            ["imageOffset": 4000, "symbol": "_NSWorkspaceHandleLSOpenResult", "symbolLocation": 312, "imageIndex": 3],
            ["imageOffset": 0x1234, "imageIndex": 0],
        ]
        let filler: [[String: Any]] = (0..<max(0, frames - top.count)).map {
            ["imageOffset": $0, "symbol": "__CFRunLoopRun_padding_frame_\($0)", "symbolLocation": $0, "imageIndex": 3]
        }
        var body: [String: Any] = [
            "modelCode": "Mac14,6", "cpuType": "ARM-64", "translated": false,
            "captureTime": "2026-09-23 18:23:32.1523 +0300",
            "osVersion": ["train": "macOS 26.6.2", "build": "25G83", "releaseType": "User"],
            "crashReporterKey": "B5616992-977A-F25E-7E25-076B609BA683",
            "sleepWakeUUID": "98BFB84B-765C-4D2B-AC5D-136A1464E9F0",
            "procPath": "/Users/jane/Downloads/MacRazer.app/Contents/MacOS/MacRazer",
            "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP", "codes": "0x1, 0x2"],
            "termination": ["namespace": "SIGNAL", "details": ["Trace/BPT trap: 5"]],
            "faultingThread": 1,
            "threads": [
                ["id": 1, "queue": "com.apple.main-thread", "frames": [top[3]]],
                ["id": 2, "triggered": true, "queue": "com.apple.launchservices.open-queue",
                 "frames": Array((top + filler).prefix(frames))],
            ],
            "usedImages": [
                ["name": "MacRazer", "path": "/Users/jane/Downloads/MacRazer.app/Contents/MacOS/MacRazer"],
                ["name": "libdispatch.dylib", "path": "/usr/lib/system/libdispatch.dylib"],
                ["path": "/usr/lib/swift/libswift_Concurrency.dylib"],
                ["name": "AppKit"],
            ],
        ]
        if let asi { body["asi"] = ["libswiftCore.dylib": [asi]] }
        let h = try! JSONSerialization.data(withJSONObject: header)
        let b = try! JSONSerialization.data(withJSONObject: body, options: .prettyPrinted)
        return h + Data("\n".utf8) + b
    }
}

final class CrashReportParserTests: XCTestCase {
    func testReadsTheCrashedThreadAndItsContext() throws {
        let r = try XCTUnwrap(CrashReportParser.parse(CrashFixture.ips()))
        XCTAssertEqual(r.appVersion, "0.6.0")
        XCTAssertEqual(r.build, "41")
        XCTAssertEqual(r.os, "macOS 26.6.2 (25G83)")
        XCTAssertEqual(r.model, "Mac14,6")
        XCTAssertEqual(r.exception, "EXC_BREAKPOINT (SIGTRAP)")
        XCTAssertEqual(r.termination, "SIGNAL: Trace/BPT trap: 5")
        XCTAssertEqual(r.queue, "com.apple.launchservices.open-queue", "the faulting thread, not the main one")
        XCTAssertEqual(r.frames, [
            "libdispatch.dylib  _dispatch_assert_queue_fail + 120",
            "libswift_Concurrency.dylib  swift_task_isCurrentExecutorImpl + 284",
            "MacRazer  closure #1 in UpdateChecker.relaunch(at:) + 52",
            "AppKit  _NSWorkspaceHandleLSOpenResult + 312",
            "MacRazer  +0x1234",
        ])
    }

    func testLeavesOutWhatIdentifiesThePersonOrTheMac() {
        let report = CrashReportParser.parse(CrashFixture.ips(
            asi: "Fatal error: /Users/jane/src/MacRazer/Foo.swift:12 boom"))!
        let json = CrashReportOutput.json(report)
        XCTAssertFalse(json.contains("jane"), json)
        XCTAssertFalse(json.contains("B5616992"), "crashReporterKey follows the Mac across reports")
        XCTAssertFalse(json.contains("98BFB84B"))
        XCTAssertEqual(report.message, "Fatal error: ~/src/MacRazer/Foo.swift:12 boom")
    }

    func testRedactsAnyHomeFolder() {
        XCTAssertEqual(CrashReportParser.redacted("/Users/jane.doe/Downloads/x.app and /Users/bob"),
                       "~/Downloads/x.app and ~")
        XCTAssertEqual(CrashReportParser.redacted("/usr/lib/system/libdispatch.dylib"),
                       "/usr/lib/system/libdispatch.dylib")
    }

    func testRefusesOtherAppsAndOtherReports() {
        XCTAssertNil(CrashReportParser.parse(CrashFixture.ips(bundleID: "com.example.other")))
        XCTAssertNil(CrashReportParser.parse(CrashFixture.ips(bugType: "288")), "a hang, not a crash")
        XCTAssertNil(CrashReportParser.parse(Data("not a report".utf8)))
        XCTAssertNil(CrashReportParser.parse(Data()))
    }

    func testCapsTheStackDepth() {
        let r = CrashReportParser.parse(CrashFixture.ips(frames: 200))!
        XCTAssertEqual(r.frames.count, CrashReportParser.maxFrames)
    }
}

final class CrashReportOutputTests: XCTestCase {
    func testANormalReportIsUntouched() {
        let r = CrashReportParser.parse(CrashFixture.ips())!
        XCTAssertEqual(CrashReportOutput.fitted(r), r)
    }

    func testDeepFramesGoFirstAndTheTopIsKept() {
        var r = CrashReportParser.parse(CrashFixture.ips(frames: 60))!
        r.comment = "short"
        let limit = CrashReportOutput.size(r) - 500
        let fitted = CrashReportOutput.fitted(r, maxBytes: limit)
        XCTAssertLessThanOrEqual(CrashReportOutput.size(fitted), limit)
        XCTAssertEqual(Array(fitted.frames.prefix(5)), Array(r.frames.prefix(5)))
        XCTAssertEqual(fitted.frames.count + (fitted.framesDropped ?? 0), 60)
        XCTAssertEqual(fitted.comment, "short", "frames give way before the comment does")
    }

    func testTheCommentIsCutOnlyOnceFramesAreDown() {
        var r = CrashReportParser.parse(CrashFixture.ips(frames: 30))!
        r.comment = String(repeating: "😀", count: 2000)
        let fitted = CrashReportOutput.fitted(r, maxBytes: 4000)
        XCTAssertLessThanOrEqual(CrashReportOutput.size(fitted), 4000)
        XCTAssertEqual(fitted.frames.count, 10)
        XCTAssertGreaterThan(CrashReportOutput.size(fitted), 4000 - 8, "only as much comment as needed goes")
        XCTAssertTrue(fitted.comment?.allSatisfy { $0 == "😀" } ?? false, "cut between emoji, not inside one")
    }
}

final class CrashLogScannerTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var scanner: CrashLogScanner!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CrashLogScannerTests-\(UUID())")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "CrashLogScannerTests-\(UUID())")
        scanner = CrashLogScanner(directories: [dir, dir.appendingPathComponent("Retired")], defaults: defaults)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func write(_ name: String, _ data: Data = CrashFixture.ips(), at date: Date) -> URL {
        let url = dir.appendingPathComponent(name)
        try! data.write(to: url)
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    func testTheFirstLookOnlyRecordsWhereItStarted() {
        let now = Date()
        write("MacRazer-2026-01-01-000000.ips", at: now.addingTimeInterval(-86400))
        XCTAssertNil(scanner.takeNewCrash(now: now), "a crash from before the feature isn't offered")
        XCTAssertEqual(defaults.object(forKey: CrashLogScanner.handledThroughKey) as? Date, now)
    }

    func testOffersTheNewestCrashOnceAndCountsThemAll() throws {
        let start = Date().addingTimeInterval(-1000)
        defaults.set(start, forKey: CrashLogScanner.handledThroughKey)
        write("MacRazer-old.ips", at: start.addingTimeInterval(-10))
        write("MacRazer-a.ips", at: start.addingTimeInterval(10))
        var newer = CrashFixture.ips()
        newer = Data(String(decoding: newer, as: UTF8.self).replacingOccurrences(of: "0.6.0", with: "0.6.1").utf8)
        write("MacRazer-b.ips", newer, at: start.addingTimeInterval(20))
        write("OtherApp-c.ips", at: start.addingTimeInterval(30))

        let found = try XCTUnwrap(scanner.takeNewCrash())
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.report.appVersion, "0.6.1", "the newest")
        XCTAssertNil(scanner.takeNewCrash(), "each crash is offered once")
    }

    func testLooksInRetiredToo() throws {
        let start = Date().addingTimeInterval(-1000)
        defaults.set(start, forKey: CrashLogScanner.handledThroughKey)
        let retired = dir.appendingPathComponent("Retired")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        let url = retired.appendingPathComponent("MacRazer-r.ips")
        try CrashFixture.ips().write(to: url)
        XCTAssertNotNil(scanner.takeNewCrash())
    }

    func testAFileThatWontParseIsPassedOverButStillMarkedHandled() {
        let start = Date().addingTimeInterval(-1000)
        defaults.set(start, forKey: CrashLogScanner.handledThroughKey)
        write("MacRazer-a.ips", at: start.addingTimeInterval(10))
        write("MacRazer-hang.ips", CrashFixture.ips(bugType: "288"), at: start.addingTimeInterval(20))
        XCTAssertEqual(scanner.takeNewCrash()?.count, 2, "the crash behind the hang is still offered")
        write("MacRazer-hang2.ips", CrashFixture.ips(bugType: "288"), at: Date().addingTimeInterval(-5))
        XCTAssertNil(scanner.takeNewCrash())
        XCTAssertNil(scanner.takeNewCrash(), "and not looked at again")
    }

    func testDontAskAgainIsRemembered() {
        XCTAssertTrue(scanner.isOffering)
        scanner.isOffering = false
        XCTAssertFalse(CrashLogScanner(directories: [dir], defaults: defaults).isOffering)
    }
}

@MainActor
final class CrashReportModelTests: XCTestCase {
    private struct Offline: Error {}

    private func model() -> CrashReportModel {
        CrashReportModel(report: CrashReportParser.parse(CrashFixture.ips())!)
    }

    func testSendsWhatThePersonAdded() async {
        let m = model()
        var sent: CrashReport?
        m.deliver = { sent = $0 }
        m.comment = "  clicked Update  "
        m.replyEmail = "jane@example.com"
        await m.send()
        XCTAssertEqual(m.state, .sent)
        XCTAssertEqual(sent?.comment, "clicked Update")
        XCTAssertEqual(sent?.replyEmail, "jane@example.com")
        XCTAssertFalse(m.canSend, "sent once")
    }

    func testABadEmailBlocksSend() {
        let m = model()
        m.deliver = { _ in }
        m.replyEmail = "not an email"
        XCTAssertFalse(m.canSend)
        XCTAssertNil(m.finalReport().replyEmail)
    }

    func testNothingToSendToMeansNoSend() {
        XCTAssertFalse(model().canSend)
    }

    func testAFailedSendCanBeTriedAgain() async {
        let m = model()
        m.deliver = { _ in throw Offline() }
        await m.send()
        guard case .failed = m.state else { return XCTFail("\(m.state)") }
        XCTAssertTrue(m.canSend)
    }

    func testWhereItCrashedIsTheFirstFrameInOurOwnCode() {
        XCTAssertEqual(model().whereItCrashed, "closure #1 in UpdateChecker.relaunch(at:) + 52")
    }

    func testTheFeatureIsOffUntilTheWorkerExists() {
        XCTAssertFalse(CrashReporting.isAvailable)
    }
}

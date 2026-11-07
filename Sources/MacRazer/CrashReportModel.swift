// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The crash window's state: the report found at launch, what the person adds, and sending.
@MainActor
final class CrashReportModel: ObservableObject {
    enum State: Equatable {
        case editing
        case sending
        case sent
        case failed(String)
    }

    let report: CrashReport
    /// How many crashes since the app last looked. Only the newest is offered.
    let count: Int
    @Published var comment = ""
    @Published var replyEmail = ""
    @Published private(set) var state = State.editing

    /// Delivers the finished report and says how it went. Nil in a build without the Worker;
    /// see `CrashReporting`.
    var deliver: CrashReporting.Deliver?

    init(report: CrashReport, count: Int = 1) {
        self.report = report
        self.count = count
    }

    var emailProblem: String? { DeviceReportOutput.emailProblem(replyEmail) }

    var canSend: Bool {
        deliver != nil && emailProblem == nil && state != .sending && state != .sent
    }

    /// The report as it would go now: with what the person typed, and cut to fit.
    func finalReport() -> CrashReport {
        var r = report
        // The device test's limits: the same Worker will take both reports.
        r.comment = DeviceReportOutput.cleaned(comment, max: DeviceReportOutput.maxComment,
                                               units: DeviceReportOutput.maxCommentUnits, singleLine: false)
        r.replyEmail = emailProblem == nil
            ? DeviceReportOutput.cleaned(replyEmail, max: DeviceReportOutput.maxEmail,
                                         units: DeviceReportOutput.maxEmail, singleLine: true) : nil
        return CrashReportOutput.fitted(r)
    }

    func send() async {
        guard canSend, let deliver else { return }
        state = .sending
        let outcome = await deliver(finalReport())
        state = outcome == .sent ? .sent : .failed(Self.sendFailure(outcome))
    }

    /// What the window says when Send fails, as the other report windows say it.
    static func sendFailure(_ outcome: DeviceReportSender.Outcome) -> String {
        DeviceTestView.sendFailure(outcome, emailHint: "email it to us at \(ProjectLinks.contactEmail)")
    }
    /// How much of the report an email link carries. Some mail apps drop a link much longer.
    static let maxMailBody = 6000

    /// An email with the report in it, for when Send fails: what they wrote, then the report
    /// shown in the window, cut short if it's too long for a link.
    var mailInstead: URL {
        let report = finalReport()
        var json = CrashReportOutput.json(report)
        if json.count > Self.maxMailBody { json = String(json.prefix(Self.maxMailBody)) + "\n(cut short)" }
        let body = (report.comment.map { $0 + "\n\n" } ?? "") + json
        return ProjectLinks.mail(subject: "MacRazer crash report: \(report.appVersion)", body: body)
    }

    // MARK: Summary

    /// The innermost frame in MacRazer's own code, which is where a reader starts. Falls back
    /// to the top frame for a crash wholly inside a system library.
    var whereItCrashed: String? {
        let own = report.frames.first { $0.hasPrefix("MacRazer ") }
        return (own ?? report.frames.first).map { line in
            // Drop the image name: in the window, a frame of our own reads better bare.
            line.hasPrefix("MacRazer  ") ? String(line.dropFirst("MacRazer  ".count)) : line
        }
    }

    // MARK: Preview

    static func preview() -> CrashReportModel {
        let model = CrashReportModel(report: CrashReport(
            appVersion: "0.6.0", build: "41", os: "macOS 26.6.2 (25G83)", model: "Mac14,6",
            cpu: "ARM-64", translated: false, time: "2026-09-23 18:23:32.0000 +0300",
            exception: "EXC_BREAKPOINT (SIGTRAP)", codes: "0x0000000000000001, 0x00000001a2b3c4d5",
            termination: "SIGNAL: Trace/BPT trap: 5", message: nil,
            queue: "com.apple.launchservices.open-queue",
            frames: [
                "libdispatch.dylib  _dispatch_assert_queue_fail + 120",
                "libdispatch.dylib  dispatch_assert_queue + 196",
                "libswift_Concurrency.dylib  swift_task_isCurrentExecutorImpl + 284",
                "MacRazer  closure #1 in UpdateChecker.relaunch(at:) + 52",
                "AppKit  _NSWorkspaceHandleLSOpenResult + 312",
            ],
            exceptionFrames: nil, framesDropped: nil,
            incident: "5E0C7B1A-8F43-4C2B-9D7E-1A2B3C4D5E6F", comment: nil, replyEmail: nil),
            count: 2)
        model.deliver = { _ in .sent }
        return model
    }

    /// The thank-you screen, for `render-crash-report sent`.
    func loadPreviewSent() { state = .sent }
    /// A send that didn't go, for `render-crash-report failed`.
    func loadPreviewFailed(_ outcome: DeviceReportSender.Outcome = .unavailable) {
        state = .failed(Self.sendFailure(outcome))
    }
}

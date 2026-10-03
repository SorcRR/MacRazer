// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// The one switch for the whole feature.
///
/// `deliver` sends a finished report to the Worker, and is nil until the Worker exists. While
/// it is nil the app doesn't look for crashes, never shows the window and hides the setting.
/// Everything else is built and tested, but a window that asks someone to send a report and
/// then has nowhere to send it is worse than no window.
enum CrashReporting {
    static let deliver: (@Sendable (CrashReport) async throws -> Void)? = nil

    static var isAvailable: Bool { deliver != nil }
}

/// What MacRazer sends about a crash: a summary of the `.ips` file macOS wrote, never the file.
///
/// The full file has the person's username in its paths, a key that identifies the Mac across
/// every report it ever sends (`crashReporterKey`), boot and sleep IDs, register contents and
/// the parent process. None of that helps fix a crash. What does is here: versions, the
/// exception, the crashed thread's stack, and the message Swift or the system attached.
/// Everything shown in the window is exactly what goes.
struct CrashReport: Codable, Equatable {
    var appVersion: String
    var build: String
    var os: String
    /// "Mac14,6": a model, not a machine.
    var model: String?
    var cpu: String?
    /// Running under Rosetta, which is worth knowing for an arm64-only crash.
    var translated: Bool?
    /// When it crashed, as macOS wrote it, with the UTC offset.
    var time: String?
    /// "EXC_BREAKPOINT (SIGTRAP)".
    var exception: String?
    var codes: String?
    /// Why the system ended the process, when it says, like a missing privacy usage string.
    var termination: String?
    /// What the crashing code said: a Swift `fatalError`, a failed precondition, an
    /// Objective-C exception's reason.
    var message: String?
    /// The dispatch queue the crash happened on, which is how the relaunch crash was found.
    var queue: String?
    /// The crashed thread, innermost first, one line a frame: "MacRazer  symbol + 52".
    var frames: [String]
    /// The stack where an Objective-C exception was thrown, which the crashed thread no
    /// longer shows by the time it aborts.
    var exceptionFrames: [String]?
    /// Frames cut to fit `CrashReportOutput.maxReportBytes`, so the report says it's partial.
    var framesDropped: Int?
    /// macOS's ID for this one crash, so the same report sent twice can be spotted.
    var incident: String?
    var comment: String?
    var replyEmail: String?
}

enum CrashReportParser {
    /// The packaged app's bundle ID. A `swift run` build crashes under the same process name
    /// with no bundle, and those are the developer's own, not reports to offer.
    static let bundleID = "com.macrazer.menubar"
    /// `bug_type` for a crash. Hangs and resource reports are other numbers and other formats.
    static let crashBugType = "309"
    /// The deepest stack worth sending. A crash is nearly always in the top few frames, and
    /// the rest is run loop.
    static let maxFrames = 60
    static let maxMessage = 1000

    /// The report, or nil when the file isn't a MacRazer crash in a format this understands.
    ///
    /// An `.ips` file is two JSON documents: a one-line header, then the body.
    static func parse(_ data: Data) -> CrashReport? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              header["bug_type"] as? String == crashBugType,
              header["bundleID"] as? String == bundleID,
              let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
        else { return nil }

        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        let crashed = (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? threads[$0] : nil }
            ?? threads.first { $0["triggered"] as? Bool == true }

        let exception = body["exception"] as? [String: Any]
        let exceptionText: String? = (exception?["type"] as? String).map { type in
            (exception?["signal"] as? String).map { "\(type) (\($0))" } ?? type
        }
        let termination = body["termination"] as? [String: Any]
        let terminationText: String? = {
            let parts = [termination?["namespace"] as? String]
                + ((termination?["details"] as? [String]) ?? []).map { Optional($0) }
            let text = parts.compactMap { $0 }.joined(separator: ": ")
            return text.isEmpty ? nil : redacted(String(text.prefix(maxMessage)))
        }()
        let osVersion = body["osVersion"] as? [String: Any]
        let os = [osVersion?["train"] as? String, (osVersion?["build"] as? String).map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        let threadQueue = crashed?["queue"] as? String
        let legacyQueue = ((body["legacyInfo"] as? [String: Any])?["threadTriggered"] as? [String: Any])?["queue"] as? String

        let exceptionFrames = ((body["lastExceptionBacktrace"] as? [[String: Any]]) ?? [])
            .prefix(maxFrames).map { frameLine($0, images: images) }

        return CrashReport(
            appVersion: header["app_version"] as? String ?? "",
            build: header["build_version"] as? String ?? "",
            os: os.isEmpty ? (header["os_version"] as? String ?? "") : os,
            model: body["modelCode"] as? String,
            cpu: body["cpuType"] as? String,
            translated: body["translated"] as? Bool,
            time: body["captureTime"] as? String ?? header["timestamp"] as? String,
            exception: exceptionText,
            codes: exception?["codes"] as? String,
            termination: terminationText,
            message: applicationMessage(body["asi"]),
            queue: threadQueue ?? legacyQueue,
            frames: ((crashed?["frames"] as? [[String: Any]]) ?? [])
                .prefix(maxFrames).map { frameLine($0, images: images) },
            exceptionFrames: exceptionFrames.isEmpty ? nil : exceptionFrames,
            framesDropped: nil,
            incident: header["incident_id"] as? String,
            comment: nil,
            replyEmail: nil)
    }

    /// "MacRazer  closure #1 in UpdateChecker.relaunch(at:) + 52", or the offset into the
    /// image when there's no symbol. An image named only by its path is cut to the file name,
    /// which is all that identifies it and keeps any home folder out.
    static func frameLine(_ frame: [String: Any], images: [[String: Any]]) -> String {
        let image: String = {
            guard let index = frame["imageIndex"] as? Int, images.indices.contains(index) else { return "???" }
            if let name = images[index]["name"] as? String { return name }
            if let path = images[index]["path"] as? String { return (path as NSString).lastPathComponent }
            return "???"
        }()
        if let symbol = frame["symbol"] as? String {
            let location = (frame["symbolLocation"] as? Int).map { " + \($0)" } ?? ""
            return redacted("\(image)  \(symbol)\(location)")
        }
        let offset = (frame["imageOffset"] as? Int).map { String(format: "0x%x", $0) } ?? "?"
        return "\(image)  +\(offset)"
    }

    /// The "Application Specific Information": `{"libswiftCore.dylib": ["Fatal error: …"]}`.
    /// A Swift crash's message records the source path it was compiled from, so it's redacted
    /// like everything else.
    static func applicationMessage(_ asi: Any?) -> String? {
        guard let asi = asi as? [String: Any] else { return nil }
        let lines = asi.keys.sorted().flatMap { (asi[$0] as? [String]) ?? [] }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : redacted(String(text.prefix(maxMessage)))
    }

    /// A home folder in a path becomes `~`, so `/Users/jane/Downloads/MacRazer.app` is sent as
    /// `~/Downloads/MacRazer.app`. The account name is the one thing in a crash that names
    /// a person.
    static func redacted(_ text: String) -> String {
        text.replacingOccurrences(of: #"/Users/[^/\s"':]+"#, with: "~", options: .regularExpression)
    }
}

enum CrashReportOutput {
    /// The Worker's limit, shared with the device test.
    static var maxReportBytes: Int { DeviceReportOutput.maxReportBytes }

    static func json(_ report: CrashReport, pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
    }

    static func size(_ report: CrashReport) -> Int { json(report, pretty: false).utf8.count }

    /// The report cut to fit, so Send never fails on size. Deep frames go first, from the
    /// bottom of the stack, where the run loop is. The top ten are kept whatever happens:
    /// they're the crash. Then, only if that isn't enough, the end of the comment.
    static func fitted(_ report: CrashReport, maxBytes: Int = maxReportBytes) -> CrashReport {
        var r = report
        let keep = 10
        while size(r) > maxBytes, (r.exceptionFrames?.count ?? 0) > keep {
            r.exceptionFrames?.removeLast()
            r.framesDropped = (r.framesDropped ?? 0) + 1
        }
        while size(r) > maxBytes, r.frames.count > keep {
            r.frames.removeLast()
            r.framesDropped = (r.framesDropped ?? 0) + 1
        }
        // Cut by bytes, not characters: an emoji is four bytes, and dropping one character
        // per byte over would throw away four times what it has to.
        while case let excess = size(r) - maxBytes, excess > 0, let comment = r.comment, !comment.isEmpty {
            var budget = comment.utf8.count - excess
            let kept = String(String.UnicodeScalarView(comment.unicodeScalars.prefix {
                budget -= $0.utf8.count
                return budget >= 0
            }))
            r.comment = kept.isEmpty ? nil : kept
        }
        return r
    }
}

/// Finds crashes that happened since the app last looked.
///
/// macOS writes every crash to `~/Library/Logs/DiagnosticReports` on its own, so nothing
/// runs inside the crashing process. An in-process handler would have to work in a process
/// that is by definition broken, and could get in the way of the system's own report.
///
/// "Since the app last looked" is a date in `UserDefaults`. The first time it runs there is
/// no date, so it records now and offers nothing: a crash from last spring, in a version
/// long since fixed, is not worth asking about.
struct CrashLogScanner {
    static let handledThroughKey = "crashReportsHandledThrough"
    static let offerKey = "offerCrashReports"

    var directories: [URL] = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        // Reports already passed to Apple are moved here, and can be the only copy.
        return [logs, logs.appendingPathComponent("Retired", isDirectory: true)]
    }()
    var defaults: UserDefaults = .standard

    /// The person said "don't ask again", or switched it off in Settings.
    var isOffering: Bool {
        get { defaults.object(forKey: Self.offerKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.offerKey) }
    }

    /// The newest MacRazer crash since the last look, and how many there were in all, or nil.
    /// Marks every one of them handled either way, so each crash is offered once at most.
    func takeNewCrash(now: Date = Date()) -> (report: CrashReport, count: Int)? {
        guard let since = defaults.object(forKey: Self.handledThroughKey) as? Date else {
            defaults.set(now, forKey: Self.handledThroughKey)
            return nil
        }
        let found = newCrashFiles(since: since)
        guard let newest = found.last else { return nil }
        defaults.set(newest.date, forKey: Self.handledThroughKey)
        // Newest first: the one most likely to be the version running now. A file that won't
        // parse (a hang, a format from a future macOS) is passed over, not offered blank.
        for file in found.reversed() {
            if let data = try? Data(contentsOf: file.url), let report = CrashReportParser.parse(data) {
                return (report, found.count)
            }
        }
        return nil
    }

    /// `MacRazer-*.ips` written after `since`, oldest first.
    func newCrashFiles(since: Date) -> [(url: URL, date: Date)] {
        directories.flatMap { dir -> [(url: URL, date: Date)] in
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            return entries.compactMap { url in
                let name = url.lastPathComponent
                guard name.hasPrefix("MacRazer-"), name.hasSuffix(".ips"),
                      let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate,
                      date > since
                else { return nil }
                return (url, date)
            }
        }
        .sorted { $0.date < $1.date }
    }
}

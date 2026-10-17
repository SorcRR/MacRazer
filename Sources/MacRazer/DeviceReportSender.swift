// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Send: posts a report to the Worker in `worker/`, which emails it to the maintainer and
/// keeps nothing. The only network request the device test makes, and only when asked.
enum DeviceReportSender {
    enum Outcome: Equatable {
        case sent
        /// The Worker refused the report itself. Sending it again won't change that.
        case refused
        /// Too many reports from here today, or too many at once.
        case tooMany
        /// No answer: offline, a timeout, or the Worker is down.
        case unavailable
    }

    /// The Worker's statuses: 200 sent, 429 rate limited, any other 4xx refused.
    static func outcome(status: Int) -> Outcome {
        switch status {
        case 200..<300: return .sent
        case 429: return .tooMany
        case 400..<500: return .refused
        default: return .unavailable
        }
    }

    /// The report as the Worker takes it: compact JSON, cut to fit its 16 KB cap, and with
    /// the reply email, which goes to the maintainer alone.
    static func request(_ report: DeviceReport, to endpoint: URL) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MacRazer/\(AppInfo.displayVersion)", forHTTPHeaderField: "User-Agent")
        let body = DeviceReportOutput.json(DeviceReportOutput.fitted(report), forPublic: false, pretty: false)
        request.httpBody = Data(body.utf8)
        return request
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func send(_ report: DeviceReport, to endpoint: URL = ProjectLinks.deviceReports,
                     transport: Transport = { try await session.data(for: $0) }) async -> Outcome {
        do {
            let (_, response) = try await transport(request(report, to: endpoint))
            return outcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .unavailable
        }
    }

    /// Ephemeral, so sending leaves no cookies or cache behind, and quick to give up: the
    /// person is watching a spinner, and Copy and the GitHub issue are right there.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()
}

import Foundation
import XCTest
@testable import MNotch

@MainActor
final class ClaudeOAuthUsageTests: XCTestCase {
    func testParsesSubscriptionWindowsAndPreservesOverage() throws {
        let windows = try XCTUnwrap(ClaudeOAuthUsage.parse(Data(#"""
        {
            "five_hour": {"utilization": 8.5, "resets_at": "2030-01-01T00:00:00.125Z"},
            "seven_day": {"utilization": 112, "resets_at": "2030-01-01T00:00:00Z"}
        }
        """#.utf8)))
        let session = try XCTUnwrap(windows.first { $0.id == "claude-session" })
        XCTAssertEqual(session.label, "5h")
        XCTAssertEqual(session.usedPercent, 8.5)
        XCTAssertEqual(session.durationMinutes, 300)
        XCTAssertEqual(try XCTUnwrap(session.resetsAt).timeIntervalSince1970, 1_893_456_000.125,
                       accuracy: 0.001)

        let weekly = try XCTUnwrap(windows.first { $0.id == "claude-week" })
        XCTAssertEqual(weekly.label, "7d")
        XCTAssertEqual(weekly.usedPercent, 112)
        XCTAssertEqual(weekly.remainingPercent, 0)
        XCTAssertEqual(weekly.durationMinutes, 10_080)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_893_456_000))
    }

    func testParsesLegacyScopedModelWindowsAndEpochReset() throws {
        let windows = try XCTUnwrap(ClaudeOAuthUsage.parse(Data(#"""
        {
            "seven_day_sonnet": {"utilization": 23, "resets_at": 1893456000.5},
            "seven_day_opus": {"utilization": 45}
        }
        """#.utf8)))
        let sonnet = try XCTUnwrap(windows.first { $0.id == "claude-week-Sonnet" })
        XCTAssertEqual(sonnet.label, "Sonnet")
        XCTAssertEqual(sonnet.usedPercent, 23)
        XCTAssertEqual(sonnet.durationMinutes, 10_080)
        XCTAssertEqual(sonnet.resetsAt, Date(timeIntervalSince1970: 1_893_456_000.5))
        let opus = try XCTUnwrap(windows.first { $0.id == "claude-week-Opus" })
        XCTAssertEqual(opus.label, "Opus")
        XCTAssertEqual(opus.usedPercent, 45)
        XCTAssertNil(opus.resetsAt)
    }

    func testParsesScopedLimitsWithoutTreatingOtherKindsAsWeeklyUsage() throws {
        let windows = try XCTUnwrap(ClaudeOAuthUsage.parse(Data(#"""
        {
            "limits": [
                {"kind": "weekly_scoped", "percent": 67.25, "resets_at": 1893456000,
                 "scope": {"model": {"display_name": "Fable"}}},
                {"kind": "spend", "percent": 91,
                 "scope": {"model": {"display_name": "Unrelated"}}}
            ]
        }
        """#.utf8)))
        XCTAssertEqual(windows, [QuotaWindow(
            id: "claude-week-Fable", label: "Fable", usedPercent: 67.25,
            durationMinutes: 10_080, resetsAt: Date(timeIntervalSince1970: 1_893_456_000)
        )])
    }

    func testScopedLimitsSkipMalformedSiblingsAndDeduplicateModelsIgnoringCase() throws {
        let windows = try XCTUnwrap(ClaudeOAuthUsage.parse(Data(#"""
        {
            "seven_day_sonnet": {"utilization": 23},
            "limits": [
                null, 7, "not a limit", [],
                {"kind": "weekly_scoped", "percent": 67.25,
                 "scope": {"model": {"display_name": "Fable"}}},
                {"kind": "weekly_scoped", "percent": 99,
                 "scope": {"model": {"display_name": "sOnNeT"}}},
                {"kind": "weekly_scoped", "percent": 91,
                 "scope": {"model": {"display_name": "fAbLe"}}}
            ]
        }
        """#.utf8)))
        XCTAssertEqual(windows.count, 2)
        let sonnet = try XCTUnwrap(windows.first { $0.id == "claude-week-Sonnet" })
        XCTAssertEqual(sonnet.usedPercent, 23)
        let fable = try XCTUnwrap(windows.first { $0.id == "claude-week-Fable" })
        XCTAssertEqual(fable.usedPercent, 67.25)
    }

    func testMissingNullAndMalformedWindowsDoNotHideValidUsage() throws {
        let windows = try XCTUnwrap(ClaudeOAuthUsage.parse(Data(#"""
        {
            "five_hour": null,
            "seven_day": {"utilization": 0, "resets_at": "invalid-date"},
            "seven_day_opus": {"utilization": false},
            "limits": [{"kind": "weekly_scoped", "percent": -1,
                        "scope": {"model": {"display_name": "Fable"}}}]
        }
        """#.utf8)))
        XCTAssertEqual(windows.map(\.id), ["claude-week"])
        XCTAssertEqual(windows.first?.usedPercent, 0)
        XCTAssertNil(windows.first?.resetsAt)
    }

    func testRejectsInvalidPercentagesAndTokenCostSummaries() {
        for value in ["-0.1", "true", "false", "null", #""8%""#, #""NaN""#,
                      #""infinity""#, "{}", "[]"] {
            let json = #"{"five_hour":{"utilization":\#(value)}}"#
            XCTAssertNil(ClaudeOAuthUsage.parse(Data(json.utf8)), "Unexpected percentage: \(value)")
        }
        for json in [
            #"{"total_cost_usd":1.25,"usage":{"input_tokens":123,"output_tokens":45}}"#,
            #"{"five_hour":null,"seven_day":null}"#,
            #"{"limits":[{"kind":"weekly_scoped","percent":3}]}"#,
            "{}", "[]", "not JSON",
        ] {
            XCTAssertNil(ClaudeOAuthUsage.parse(Data(json.utf8)))
        }
    }

    func testUsageRequestUsesReadOnlyOAuthEndpoint() {
        let request = ClaudeOAuthUsage.request(accessToken: "test-access-token")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertTrue(request.value(forHTTPHeaderField: "anthropic-beta")?
            .contains("oauth-2025-04-20") == true)
        XCTAssertNil(request.httpBody)
    }

    func testSuccessfulHTTPResponseReturnsQuotaWindows() async throws {
        let outcome = await fetch(response: .http(200, Data(#"{"five_hour":{"utilization":12}}"#.utf8)))
        guard case .windows(let windows) = outcome else {
            XCTFail("Expected subscription quota windows")
            return
        }
        XCTAssertEqual(windows.map(\.id), ["claude-session"])
        XCTAssertEqual(windows.first?.usedPercent, 12)
    }

    func testHTTPFailuresDistinguishSignInAndRateLimiting() async {
        for status in [401, 403] {
            let outcome = await fetch(response: .http(status, Data()))
            XCTAssertEqual(outcome, .unavailable(.authenticationRequired))
        }
        let throttled = await fetch(response: .http(429, Data()))
        XCTAssertEqual(throttled, .unavailable(.rateLimited))
    }

    func testSuccessfulHTTPResponseStillRequiresRealQuotaData() async {
        for body in ["not JSON", "{}", #"{"usage":{"input_tokens":42},"total_cost_usd":0.1}"#] {
            let outcome = await fetch(response: .http(200, Data(body.utf8)))
            XCTAssertEqual(outcome, .unavailable(.invalidResponse))
        }
    }

    func testNetworkFailuresAndCancellationAreDistinct() async {
        let failed = await fetch(response: .failure(.cannotConnectToHost))
        XCTAssertEqual(failed, .unavailable(.connectionFailed))
        let cancelled = await fetch(response: .failure(.cancelled))
        XCTAssertEqual(cancelled, .unavailable(.cancelled))
    }

    func testProcessEnvironmentOnlyReturnsOAuthAndHostFromEnvironmentSection() {
        let data = processArguments(
            arguments: ["claude", "-p", "CLAUDE_CODE_OAUTH_TOKEN=argument-only"],
            environment: [
                "PATH=/usr/bin:/bin", "ANTHROPIC_API_KEY=ignored-api-key",
                "CLAUDE_CODE_OAUTH_TOKEN=actual-test-token=with-equals",
                "ANTHROPIC_BASE_URL=https://api.anthropic.com",
                "PREFIX_CLAUDE_CODE_OAUTH_TOKEN=ignored-prefix",
            ]
        )
        XCTAssertEqual(ClaudeOAuthCredentials.environment(from: data), [
            "CLAUDE_CODE_OAUTH_TOKEN": "actual-test-token=with-equals",
            "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
        ])
    }

    func testProcessEnvironmentDoesNotMistakePromptForOAuthToken() {
        let data = processArguments(
            arguments: ["claude", "-p", "CLAUDE_CODE_OAUTH_TOKEN=argument-only"],
            environment: ["PATH=/usr/bin"]
        )
        XCTAssertEqual(ClaudeOAuthCredentials.environment(from: data), [:])
    }

    func testTruncatedOrMalformedProcessArgumentsAreIgnored() {
        XCTAssertEqual(ClaudeOAuthCredentials.environment(from: Data()), [:])
        XCTAssertEqual(ClaudeOAuthCredentials.environment(from: Data([1, 0])), [:])
        var negativeCount: Int32 = -1
        let malformed = withUnsafeBytes(of: &negativeCount) { Data($0) }
            + Data("claude\0CLAUDE_CODE_OAUTH_TOKEN=not-an-environment\0".utf8)
        XCTAssertEqual(ClaudeOAuthCredentials.environment(from: malformed), [:])
        var truncated = processArguments(arguments: ["claude"], environment: [])
        truncated.removeLast(3)
        XCTAssertEqual(ClaudeOAuthCredentials.environment(from: truncated), [:])
    }

    private func fetch(response: ClaudeQuotaURLProtocol.Response) async -> ClaudeOAuthUsage.Outcome {
        let token = "quota-test-\(UUID().uuidString)"
        ClaudeQuotaURLProtocol.responses.set(response, for: "Bearer \(token)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeQuotaURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            ClaudeQuotaURLProtocol.responses.remove("Bearer \(token)")
        }
        return await ClaudeOAuthUsage.fetch(accessToken: token, session: session)
    }

    private func processArguments(arguments: [String], environment: [String]) -> Data {
        var count = Int32(arguments.count)
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(Data("/Applications/Claude.app/Contents/MacOS/claude\0\0\0".utf8))
        for value in arguments + environment {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        data.append(0)
        return data
    }
}

private final class ClaudeQuotaURLProtocol: URLProtocol, @unchecked Sendable {
    enum Response: Sendable {
        case http(Int, Data)
        case failure(URLError.Code)
    }

    final class Responses: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Response] = [:]

        func set(_ response: Response, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            values[key] = response
        }

        func get(_ key: String) -> Response? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func remove(_ key: String) {
            lock.lock()
            defer { lock.unlock() }
            values.removeValue(forKey: key)
        }
    }

    static let responses = Responses()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              let result = Self.responses.get(authorization),
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch result {
        case .http(let status, let body):
            guard let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

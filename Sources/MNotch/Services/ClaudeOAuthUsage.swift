import CoreFoundation
import Darwin
import Foundation

/// The same read-only endpoint used by Claude Desktop's plan-usage view.
/// Access tokens are never refreshed, written to disk, or included in diagnostics.
enum ClaudeOAuthUsage {
    enum Failure: Equatable, Sendable {
        case noCredentials, authenticationRequired, rateLimited
        case invalidResponse, connectionFailed, cancelled
    }

    enum Outcome: Equatable, Sendable {
        case windows([QuotaWindow])
        case unavailable(Failure)
    }

    static func fetch() async -> Outcome {
        let tokens = await Task.detached(priority: .utility) {
            ClaudeOAuthCredentials.accessTokens()
        }.value
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        guard !tokens.isEmpty else { return .unavailable(.noCredentials) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for token in tokens {
            let outcome = await fetch(accessToken: token, session: session)
            // A long-lived Desktop child can retain an expired launch token.
            // Try another existing sign-in, without rotating either credential.
            if outcome == .unavailable(.authenticationRequired) { continue }
            return outcome
        }
        return .unavailable(.authenticationRequired)
    }

    static func request(accessToken: String) -> URLRequest {
        // Never derive the destination from another process's environment.
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func fetch(accessToken: String, session: URLSession) async -> Outcome {
        do {
            let (data, response) = try await session.data(for: request(accessToken: accessToken))
            guard !Task.isCancelled else { return .unavailable(.cancelled) }
            guard let response = response as? HTTPURLResponse else { return .unavailable(.invalidResponse) }
            switch response.statusCode {
            case 200:
                guard data.count <= 1_024 * 1_024, let windows = parse(data) else {
                    return .unavailable(.invalidResponse)
                }
                return .windows(windows)
            case 401, 403: return .unavailable(.authenticationRequired)
            case 429: return .unavailable(.rateLimited)
            default: return .unavailable(.connectionFailed)
            }
        } catch {
            let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
            return .unavailable(cancelled ? .cancelled : .connectionFailed)
        }
    }

    static func parse(_ data: Data) -> [QuotaWindow]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var windows: [QuotaWindow] = []
        func append(_ raw: Any?, id: String, label: String, minutes: Int, percentKey: String = "utilization") {
            guard let raw = raw as? [String: Any], let percent = number(raw[percentKey]), percent >= 0,
                  !windows.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else { return }
            windows.append(QuotaWindow(
                id: id, label: label, usedPercent: percent, durationMinutes: minutes,
                resetsAt: resetDate(raw["resets_at"])
            ))
        }
        append(root["five_hour"], id: "claude-session", label: "5h", minutes: 300)
        append(root["seven_day"], id: "claude-week", label: "7d", minutes: 10_080)
        for scope in ["sonnet", "opus"] {
            let label = scope.capitalized
            append(root["seven_day_\(scope)"], id: "claude-week-\(label)", label: label, minutes: 10_080)
        }
        for rawLimit in root["limits"] as? [Any] ?? [] {
            guard let limit = rawLimit as? [String: Any],
                  limit["kind"] as? String == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String else { continue }
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= 80 else { continue }
            append(limit, id: "claude-week-\(label)", label: label, minutes: 10_080, percentKey: "percent")
        }
        return windows.isEmpty ? nil : windows
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func resetDate(_ raw: Any?) -> Date? {
        if let seconds = number(raw) { return SafeNumeric.date(seconds: seconds) }
        guard let text = raw as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

enum ClaudeOAuthCredentials {
    private static let tokenKey = "CLAUDE_CODE_OAUTH_TOKEN"
    private static let baseURLKey = "ANTHROPIC_BASE_URL"

    /// Reuse existing first-party sign-ins only. Desktop gives its own CLI a
    /// bearer token even when the separately installed `claude` is logged out.
    /// Same-user launch environments need no prompt. CLI Keychain credentials
    /// are used only when macOS already permits access without interaction.
    static func accessTokens() -> [String] {
        var tokens: [String] = []
        func append(_ environment: [String: String]) {
            guard let token = environment[tokenKey], token.hasPrefix("sk-ant-oat"),
                  token.utf8.count <= 16_384,
                  !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { return }
            if let base = environment[baseURLKey], !base.isEmpty {
                guard let url = URL(string: base), url.scheme == "https", url.host == "api.anthropic.com",
                      url.user == nil, url.password == nil, url.port == nil || url.port == 443,
                      url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil else { return }
            }
            if !tokens.contains(token) { tokens.append(token) }
        }
        append(ProcessInfo.processInfo.environment)

        for token in ClaudeDesktopCredentials.accessTokens() { append([tokenKey: token]) }

        // The Linux-style credential file is also used by some native installs.
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let credentials = URL(fileURLWithPath: config).appendingPathComponent(".credentials.json")
        if let data = try? BoundedFileReader.read(credentials, limit: 1_024 * 1_024),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = root["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String {
            append([tokenKey: token])
        }

        if let token = keychainAccessToken() { append([tokenKey: token]) }

        let desktopRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true).path + "/"
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard bytes > 0, bytes <= 4 * 1_024 * 1_024 else { return tokens }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 32)
        let count = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return tokens }
        for pid in pids.prefix(Int(count) / MemoryLayout<pid_t>.stride).sorted(by: >) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard executable.hasPrefix(desktopRoot), executable.hasSuffix("/claude.app/Contents/MacOS/claude") else { continue }
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
            var size = buffer.count
            let status = buffer.withUnsafeMutableBytes { bytes in
                sysctl(&mib, UInt32(mib.count), bytes.baseAddress, &size, nil, 0)
            }
            guard status == 0 else { continue }
            append(environment(from: Data(buffer.prefix(size))))
            if tokens.count >= 4 { break }
        }
        return tokens
    }

    private static func keychainAccessToken() -> String? {
        guard let data = ClaudeCredentialKeychain.read(service: "Claude Code-credentials").data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }

    /// Parse KERN_PROCARGS2 structurally: argv can contain text resembling an
    /// environment assignment, so scraping `ps` output is not safe here.
    static func environment(from data: Data) -> [String: String] {
        guard data.count >= MemoryLayout<Int32>.size else { return [:] }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 65_536 else { return [:] }
        let bytes = [UInt8](data)
        var position = MemoryLayout<Int32>.size
        func string() -> String? {
            guard position < bytes.count,
                  let end = bytes[position...].firstIndex(of: 0) else { return nil }
            defer { position = end + 1 }
            return String(bytes: bytes[position..<end], encoding: .utf8)
        }
        guard string() != nil else { return [:] } // executable path
        while position < bytes.count, bytes[position] == 0 { position += 1 }
        for _ in 0..<argc { guard string() != nil else { return [:] } }
        var result: [String: String] = [:]
        while let entry = string(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            if key == tokenKey || key == baseURLKey {
                result[key] = String(entry[entry.index(after: equals)...])
            }
        }
        return result
    }
}

import Foundation
import Security

/// Read-only client for the official Claude subscription usage endpoint. It
/// reuses Claude Code's own OAuth login (stored in the login Keychain), so the
/// notch shows real 5h / 7d headroom with no terminal session and no setup
/// beyond the one-time Keychain access prompt.
///
/// Deliberately never refreshes the OAuth token itself: Claude Code's refresh
/// tokens are single-use and rotate, so refreshing here would invalidate the
/// user's Claude Code session. When the stored access token has expired we
/// simply wait for Claude Code to refresh it and re-read the Keychain.
@MainActor
final class ClaudeUsageClient {
    /// Fresh official rate-limit windows.
    var onLimits: ((ClaudeRateLimits) -> Void)?
    /// Couldn't fetch (no login, expired, scope/HTTP error, throttled). The
    /// message is for display; existing windows should be kept as stale.
    var onUnavailable: ((String) -> Void)?

    private var task: Task<Void, Never>?
    /// Set after a 429; suppresses fetches until it passes (no Retry-After
    /// header is sent, so we back off on our own).
    private var throttledUntil: Date?
    private var backoff: TimeInterval = 180

    private nonisolated static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private nonisolated static let service = "Claude Code-credentials"

    func start() {
        refresh()
    }

    func refresh() {
        guard task == nil else { return }
        if let until = throttledUntil, until > .now { return }
        task = Task { [weak self] in
            let outcome = await Self.fetch()
            guard let self, !Task.isCancelled else { return }
            self.apply(outcome)
            self.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func apply(_ outcome: Outcome) {
        switch outcome {
        case .limits(let limits):
            throttledUntil = nil
            backoff = 180
            onLimits?(limits)
        case .throttled:
            throttledUntil = Date().addingTimeInterval(backoff)
            backoff = min(backoff * 2, 900)
            onUnavailable?("Usage rate-limited — retrying later")
        case .unavailable(let message):
            onUnavailable?(message)
        }
    }

    // MARK: - Fetch (off the main actor)

    private enum Outcome: Sendable {
        case limits(ClaudeRateLimits)
        case throttled
        case unavailable(String)
    }

    private nonisolated static func fetch() async -> Outcome {
        // Keychain access can block on a system prompt — keep it off the main actor.
        let blob = await Task.detached(priority: .utility) { readCredentialsBlob() }.value
        guard let blob else {
            return .unavailable("Sign in to Claude Code for usage")
        }
        guard let creds = parseCredentials(blob) else {
            return .unavailable("Claude Code login not found")
        }
        guard creds.expiresAt > Date() else {
            // Let Claude Code rotate its own token; we'll pick it up next poll.
            return .unavailable("Claude Code login expired")
        }
        if let scopes = creds.scopes, !scopes.contains("user:profile") {
            return .unavailable("Re-login to Claude Code for usage")
        }

        var request = URLRequest(url: usageURL, timeoutInterval: 15)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable("Usage: no response")
            }
            switch http.statusCode {
            case 200:
                guard let limits = parseUsage(data) else {
                    return .unavailable("Usage: unexpected response")
                }
                return .limits(limits)
            case 401, 403:
                return .unavailable("Re-login to Claude Code for usage")
            case 429:
                return .throttled
            default:
                return .unavailable("Usage HTTP \(http.statusCode)")
            }
        } catch {
            return .unavailable("Usage request failed")
        }
    }

    // MARK: - Keychain

    struct Credentials {
        let accessToken: String
        let expiresAt: Date
        let scopes: [String]?
    }

    private nonisolated static func readCredentialsBlob() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return data
    }

    /// Parses the `claudeAiOauth` blob Claude Code stores. `expiresAt` is epoch
    /// milliseconds.
    nonisolated static func parseCredentials(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let millis = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        return Credentials(
            accessToken: token,
            expiresAt: Date(timeIntervalSince1970: millis / 1000),
            scopes: oauth["scopes"] as? [String]
        )
    }

    // MARK: - Response parsing

    /// The usage endpoint returns per-window `{ utilization, resets_at }` with
    /// `resets_at` as an ISO-8601 string; normalize to the shared model.
    nonisolated static func parseUsage(_ data: Data) -> ClaudeRateLimits? {
        struct Window: Decodable { let utilization: Double?; let resets_at: String? }
        struct Response: Decodable { let five_hour: Window?; let seven_day: Window? }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }
        func window(_ w: Window?) -> ClaudeQuotaWindow? {
            guard let w, let used = w.utilization else { return nil }
            return ClaudeQuotaWindow(usedPercentage: used, resetsAt: epoch(w.resets_at))
        }
        let limits = ClaudeRateLimits(
            fiveHour: window(decoded.five_hour),
            sevenDay: window(decoded.seven_day)
        )
        return limits.normalizedWindows.isEmpty ? nil : limits
    }

    private nonisolated static func epoch(_ iso: String?) -> Double? {
        guard let iso else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: iso) { return date.timeIntervalSince1970 }
        let plain = ISO8601DateFormatter()
        return plain.date(from: iso)?.timeIntervalSince1970
    }

    // MARK: - User-Agent

    /// The usage endpoint throttles hard unless the request looks like Claude
    /// Code, so send its version (best-effort detection, sane fallback).
    private nonisolated static let userAgent = "claude-code/\(installedClaudeVersion() ?? "2.1.0")"

    private nonisolated static func installedClaudeVersion() -> String? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude/claude-code")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: base.path
        ) else { return nil }
        return entries
            .filter { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
            .max { versionLess($0, $1) }
    }

    private nonisolated static func versionLess(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for (x, y) in zip(pa, pb) where x != y { return x < y }
        return pa.count < pb.count
    }
}

import Foundation

/// Reads subscription usage through Claude's read-only OAuth usage endpoint,
/// reusing an existing Desktop or CLI sign-in without refreshing its token.
///
/// Fetches are single-flighted and cancellation keeps stop/start from leaving
/// overlapping network requests behind.
@MainActor
final class ClaudeUsageClient {
    /// Fresh usage windows (session + weekly), newest first.
    var onWindows: (([QuotaWindow]) -> Void)?
    /// Couldn't read usage (no existing sign-in, network failure, unparseable). Message is
    /// for display; existing windows should be kept as stale.
    var onUnavailable: ((String) -> Void)?

    private var task: Task<Void, Never>?
    private var isActive = false
    private var refreshAfterFlight = false
    /// After a failure, suppress the timer-driven poll until this time so a
    /// throttled endpoint isn't hammered every interval (manual refresh forces).
    private var throttledUntil: Date?
    private var backoff: TimeInterval = 180

    func start() {
        isActive = true
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        guard task == nil else {
            // stop→start can occur before the cancelled request has completed.
            // Remember the new demand so completion immediately starts a fresh
            // fetch instead of leaving Claude absent until the 3-minute timer.
            if force { refreshAfterFlight = true }
            return
        }
        if !force, let until = throttledUntil, until > Date() { return }
        task = Task { [weak self] in
            let outcome = await Self.fetch()
            guard let self else { return }
            let cancelled = Task.isCancelled
            self.task = nil
            if !cancelled {
                switch outcome {
                case .windows(let windows):
                    self.throttledUntil = nil
                    self.backoff = 180
                    self.onWindows?(windows)
                case .unavailable(let message):
                    self.throttledUntil = Date().addingTimeInterval(self.backoff)
                    self.backoff = min(self.backoff * 2, 900)
                    self.onUnavailable?(message)
                }
            }
            if self.isActive, self.refreshAfterFlight {
                self.refreshAfterFlight = false
                self.refresh(force: true)
            }
        }
    }

    func stop() {
        isActive = false
        refreshAfterFlight = false
        task?.cancel()
        // Let the cancelled task clear itself before a restart fetches again.
    }

    private enum Outcome: Sendable {
        case windows([QuotaWindow])
        case unavailable(String)
    }

    private nonisolated static func fetch() async -> Outcome {
        switch await ClaudeOAuthUsage.fetch() {
        case .windows(let windows): return .windows(windows)
        case .unavailable(.rateLimited): return .unavailable("Claude usage temporarily rate limited")
        case .unavailable(.invalidResponse), .unavailable(.connectionFailed):
            return .unavailable("Couldn't read Claude usage")
        case .unavailable(.cancelled): return .unavailable("Couldn't read Claude usage")
        case .unavailable(.noCredentials), .unavailable(.authenticationRequired):
            return .unavailable("Connect Claude in Settings to read usage")
        }
    }

    // MARK: - Locating the CLI

    /// The located `claude` binary path, or nil if it isn't installed. For the
    /// Settings UI; may spawn a login shell on the first call, so run it off the
    /// main thread.
    nonisolated static func cliPath() -> String? {
        resolveClaude()?.claude
    }

    private struct Resolution: Sendable { let claude: String; let path: String }

    // Cache the located binary so we don't spawn an interactive login shell on
    // every poll. A failed lookup is never cached, so "it works after I install
    // the CLI" without an app restart.
    private nonisolated(unsafe) static var cachedResolution: Resolution?
    private nonisolated static let resolutionLock = NSLock()

    /// Find `claude` using the login PATH, inherited PATH and deterministic
    /// package-manager locations. Cached once found. The shell is deliberately
    /// non-interactive: interactive plug-ins can wait for input indefinitely.
    private nonisolated static func resolveClaude(cancellation: SubprocessCancellation = SubprocessCancellation()) -> Resolution? {
        resolutionLock.lock(); defer { resolutionLock.unlock() }
        if let cached = cachedResolution,
           FileManager.default.isExecutableFile(atPath: cached.claude) {
            return cached
        }
        cachedResolution = nil
        let path = loginPath(cancellation: cancellation)
        guard let claude = locate("claude", onPath: path) else { return nil }
        let resolution = Resolution(claude: claude, path: path)
        cachedResolution = resolution
        return resolution
    }

    private nonisolated static func loginPath(cancellation: SubprocessCancellation) -> String {
        let mark = "__MNOTCH_PATH__"
        let out = runZsh(["-lc", "printf '%s%s%s' '\(mark)' \"$PATH\" '\(mark)'"], cancellation: cancellation)
        var shellPath: String?
        if let start = out.range(of: mark),
           let end = out.range(of: mark, range: start.upperBound..<out.endIndex) {
            let value = String(out[start.upperBound..<end.lowerBound])
            if !value.isEmpty { shellPath = value }
        }
        return mergeSearchPaths([
            shellPath,
            ProcessInfo.processInfo.environment["PATH"],
            fallbackPath(),
        ].compactMap { $0 })
    }

    private nonisolated static func runZsh(
        _ args: [String], cancellation: SubprocessCancellation
    ) -> String {
        let result = SubprocessRunner.runSync(.init(
            executable: "/bin/zsh", arguments: args, timeout: 5,
            outputLimit: 256 * 1_024
        ), cancellation: cancellation)
        guard result.succeeded else { return "" }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private nonisolated static func locate(_ name: String, onPath path: String) -> String? {
        let fm = FileManager.default
        for dir in path.split(separator: ":").map(String.init) where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private nonisolated static func fallbackPath() -> String {
        let home = NSHomeDirectory()
        var directories = [
            "\(home)/.local/bin", "\(home)/.local/node/bin",
            "\(home)/.volta/bin", "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims", "\(home)/.bun/bin",
            "\(home)/Library/pnpm", "\(home)/.npm-global/bin",
            "\(home)/.local/share/fnm/aliases/default/bin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        directories += versionedBinDirectories(
            root: "\(home)/.nvm/versions/node",
            suffix: "bin"
        )
        directories += versionedBinDirectories(
            root: "\(home)/.local/share/fnm/node-versions",
            suffix: "installation/bin"
        )
        directories += versionedBinDirectories(
            root: "\(home)/.fnm/node-versions",
            suffix: "installation/bin"
        )
        return mergeSearchPaths(directories)
    }

    private nonisolated static func versionedBinDirectories(
        root: String,
        suffix: String
    ) -> [String] {
        let fm = FileManager.default
        guard let versions = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return versions.sorted(by: >).map {
            (root as NSString).appendingPathComponent("\($0)/\(suffix)")
        }
    }

    /// Preserve first-hit precedence while preventing a huge duplicated PATH.
    nonisolated static func mergeSearchPaths(_ paths: [String]) -> String {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths {
            for component in path.split(separator: ":").map(String.init)
            where !component.isEmpty && seen.insert(component).inserted {
                result.append(component)
            }
        }
        return result.joined(separator: ":")
    }
}

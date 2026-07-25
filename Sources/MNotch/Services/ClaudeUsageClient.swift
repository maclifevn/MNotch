import Foundation

/// Collects a pipe's bytes on a background queue so both of a process's pipes
/// can be drained concurrently without a full-buffer deadlock.
private final class PipeDataBox: @unchecked Sendable { var data = Data() }

/// A tiny synchronized buffer used by `FileHandle.readabilityHandler`.  Reading
/// subprocess output this way matters for login shells: a broken shell startup
/// file can keep a descendant (and therefore the pipe) alive after zsh exits.
/// `readDataToEndOfFile()` would then wait forever even though we timed zsh out.
private final class LockedPipeDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// Reads Claude subscription usage by asking the local `claude` CLI itself
/// (`claude -p /usage`). The CLI owns its own OAuth login, so MNotch never
/// touches the Keychain, never triggers an access prompt, and never risks
/// rotating the token — the user is never asked to authorize anything or log in
/// again. Technique adapted from openhoangnc/claude-usage-stats.
///
/// Fetches are single-flighted: two concurrent `claude` processes could race to
/// refresh (and rotate) the shared OAuth token, which is exactly what forces a
/// surprise re-login, so only ever one runs at a time.
@MainActor
final class ClaudeUsageClient {
    /// Fresh usage windows (session + weekly), newest first.
    var onWindows: (([QuotaWindow]) -> Void)?
    /// Couldn't read usage (CLI missing, not logged in, unparseable). Message is
    /// for display; existing windows should be kept as stale.
    var onUnavailable: ((String) -> Void)?

    private var task: Task<Void, Never>?
    private var isActive = false
    private var refreshAfterFlight = false
    /// After a failure, suppress the timer-driven poll until this time so a
    /// throttled endpoint isn't hammered every interval (manual refresh forces).
    private var throttledUntil: Date?
    private var backoff: TimeInterval = 180

    // The currently running CLI process, so stop() can actually terminate it.
    private nonisolated(unsafe) static var runningProcess: Process?
    private nonisolated static let processLock = NSLock()

    func start() {
        isActive = true
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        guard task == nil else {
            // stop→start can occur before the terminated CLI has fully reaped.
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
        // Terminate the running process and let the task nil itself once the
        // (now-terminated) fetch returns — never nil `task` here, or a restart
        // could launch a second concurrent `claude` while this one is alive.
        Self.terminate()
    }

    private nonisolated static func terminate() {
        processLock.lock(); defer { processLock.unlock() }
        if runningProcess?.isRunning == true { runningProcess?.terminate() }
    }

    private enum Outcome: Sendable {
        case windows([QuotaWindow])
        case unavailable(String)
    }

    private nonisolated static func fetch() async -> Outcome {
        await Task.detached(priority: .utility) { fetchSync() }.value
    }

    private nonisolated static func fetchSync() -> Outcome {
        guard let resolution = resolveClaude() else {
            return .unavailable("Install claude CLI for usage")
        }
        let output = runUsage(claude: resolution.claude, path: resolution.path)
        if output.localizedCaseInsensitiveContains("command not found") {
            return .unavailable("Install claude CLI for usage")
        }
        if let windows = parse(output), !windows.isEmpty {
            return .windows(windows)
        }
        if isAuthError(output) {
            return .unavailable("Run claude /login for usage")
        }
        return .unavailable("Couldn't read Claude usage")
    }

    // MARK: - Running the CLI

    /// Run `claude -p /usage` under the user's login PATH and return combined
    /// stdout+stderr. Bounded by a hard timeout so a hung CLI can't wedge polling.
    private nonisolated static func runUsage(claude: String, path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "/usage"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["DISABLE_AUTOUPDATER"] = "1"
        env["DISABLE_NON_ESSENTIAL_MODEL_CALLS"] = "1"
        env["CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION"] = "1"
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return "" }
        processLock.lock(); runningProcess = process; processLock.unlock()
        defer { processLock.lock(); runningProcess = nil; processLock.unlock() }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: killer)

        // Drain stderr concurrently so a child that fills one pipe's buffer
        // while the other stays open can't deadlock the read.
        let errBox = PipeDataBox()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errDone.wait()
        killer.cancel()

        return String(decoding: out, as: UTF8.self) + "\n" + String(decoding: errBox.data, as: UTF8.self)
    }

    private nonisolated static func isAuthError(_ text: String) -> Bool {
        // Specific phrases only — bare "sign in"/"credentials" appear in normal
        // prose and would wrongly tell a logged-in user to re-authenticate.
        let low = text.lowercased()
        return low.contains("not signed in")
            || low.contains("not logged in")
            || low.contains("please log in")
            || low.contains("please sign in")
            || low.contains("/login")
            || low.contains("no credentials")
    }

    // MARK: - Parsing

    /// Parse `/usage` text into quota windows. Handles the one-line format the
    /// CLI prints, e.g.:
    ///   Current session: 4% used · resets Jul 15 at 6:30pm (Asia/Saigon)
    ///   Current week (all models): 74% used · resets Jul 17 at 8pm (Asia/Saigon)
    ///   Current week (Fable): 57% used · resets Jul 17 at 8pm (Asia/Saigon)
    nonisolated static func parse(_ text: String) -> [QuotaWindow]? {
        var windows: [QuotaWindow] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Generous bound only to skip prose paragraphs; the title-prefix
            // check below is what actually gates to real window lines. (90 was
            // too tight — a long IANA timezone at 100% used could exceed it.)
            guard line.count <= 200,
                  let colon = line.firstIndex(of: ":") else { continue }
            let title = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let rest = String(line[line.index(after: colon)...])
            guard let percent = percentUsed(in: rest) else { continue }

            let (id, label, minutes): (String, String, Int)
            if title.hasPrefix("current session") {
                (id, label, minutes) = ("claude-session", "5h", 300)
            } else if title.hasPrefix("current week (all models)") {
                (id, label, minutes) = ("claude-week", "7d", 10_080)
            } else if title.hasPrefix("current week") {
                // Scoped weekly, e.g. "current week (fable)" → label the model.
                let scope = scopeName(title) ?? "wk"
                (id, label, minutes) = ("claude-week-\(scope)", scope, 10_080)
            } else {
                continue
            }

            let reset = rest.components(separatedBy: "·").dropFirst().first
                .flatMap { parseCLIDate($0) }
            windows.append(QuotaWindow(
                id: id,
                label: label,
                usedPercent: Double(percent),
                durationMinutes: minutes,
                resetsAt: reset
            ))
        }
        // Order: session first, then all-models weekly, then any scoped weekly,
        // so the compact header shows 5h + 7d(all).
        let rank: (QuotaWindow) -> Int = {
            if $0.id == "claude-session" { return 0 }
            if $0.id == "claude-week" { return 1 }
            return 2
        }
        return windows.isEmpty ? nil : windows.sorted { rank($0) < rank($1) }
    }

    /// The model name from a "current week (fable)" title, title-cased.
    private nonisolated static func scopeName(_ title: String) -> String? {
        guard let open = title.firstIndex(of: "("),
              let close = title.firstIndex(of: ")"), open < close else { return nil }
        let inner = title[title.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }
        return inner.prefix(1).uppercased() + inner.dropFirst()
    }

    /// Integer N from an "N% used" fragment (guards on the "used" suffix so
    /// prose containing a percent doesn't match).
    private nonisolated static func percentUsed(in text: String) -> Int? {
        guard let r = text.range(
            of: "[0-9]{1,3}%[ ]*used",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        return Int(text[r].prefix { $0.isNumber })
    }

    // MARK: - Reset date parsing

    /// Parse a reset fragment into a Date. Handles the dated form
    /// ("resets Jul 15 at 6:30pm (Asia/Saigon)") and the same-day time-only form
    /// ("resets 7pm (Asia/Saigon)"). Returns nil if neither matches.
    nonisolated static func parseCLIDate(_ s: String) -> Date? {
        var cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("resets") {
            cleaned = String(cleaned.dropFirst("resets".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var tz: TimeZone?
        if let open = cleaned.firstIndex(of: "("),
           let close = cleaned.firstIndex(of: ")"), open < close {
            tz = TimeZone(identifier: String(cleaned[cleaned.index(after: open)..<close]))
            cleaned = String(cleaned[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let zone = tz ?? .current

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone

        for format in ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d 'at' h:mm a", "MMM d 'at' h a"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) {
                return applyCurrentYear(to: date, zone: zone)
            }
        }
        for format in ["h:mma", "ha", "h:mm a", "h a"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = zone
                let hm = cal.dateComponents([.hour, .minute], from: date)
                var comp = cal.dateComponents([.year, .month, .day], from: Date())
                comp.hour = hm.hour; comp.minute = hm.minute; comp.second = 0
                comp.timeZone = zone
                guard var result = cal.date(from: comp) else { return nil }
                if result.timeIntervalSinceNow < -60 {
                    result = cal.date(byAdding: .day, value: 1, to: result) ?? result
                }
                return result
            }
        }
        return nil
    }

    /// Stamp a month/day-only parse (which defaults to year 2000) with the
    /// current year, nudging across a new-year boundary if needed.
    private nonisolated static func applyCurrentYear(to date: Date, zone: TimeZone) -> Date? {
        let year = Calendar.current.component(.year, from: Date())
        let parsed = Calendar.current.dateComponents(in: zone, from: date)
        var comp = DateComponents()
        comp.timeZone = zone
        comp.year = year
        comp.month = parsed.month
        comp.day = parsed.day
        comp.hour = parsed.hour
        comp.minute = parsed.minute
        // Fail to nil rather than returning the year-2000 parse, which would
        // render a reset ~26 years in the past.
        guard let result = Calendar.current.date(from: comp) else { return nil }
        if result.timeIntervalSinceNow < -86_400 * 180 {
            comp.year = year + 1
            return Calendar.current.date(from: comp)
        } else if result.timeIntervalSinceNow > 86_400 * 180 {
            comp.year = year - 1
            return Calendar.current.date(from: comp)
        }
        return result
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
    private nonisolated static func resolveClaude() -> Resolution? {
        resolutionLock.lock(); defer { resolutionLock.unlock() }
        if let cached = cachedResolution,
           FileManager.default.isExecutableFile(atPath: cached.claude) {
            return cached
        }
        cachedResolution = nil
        let path = loginPath()
        guard let claude = locate("claude", onPath: path) else { return nil }
        let resolution = Resolution(claude: claude, path: path)
        cachedResolution = resolution
        return resolution
    }

    private nonisolated static func loginPath() -> String {
        let mark = "__MNOTCH_PATH__"
        let out = runZsh(["-lc", "printf '%s%s%s' '\(mark)' \"$PATH\" '\(mark)'"])
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

    private nonisolated static func runZsh(_ args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        let output = LockedPipeDataBox()
        let finished = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { output.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            return ""
        }

        // Shell profiles are user-controlled. A prompt, network plug-in, or
        // stale mount must never occupy a worker forever or wedge quota refresh.
        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
        }
        reader.readabilityHandler = nil
        try? reader.close()
        return String(decoding: output.snapshot(), as: UTF8.self)
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

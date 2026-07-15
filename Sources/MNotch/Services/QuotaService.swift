import Foundation
import Observation

struct QuotaUsageSample: Sendable {
    let date: Date
    let tokens: Int
}

/// Pure JSON extraction kept separate so transcript parsing can be tested
/// without constructing the app service.
enum QuotaUsageParser {
    static func fields(from data: Data) -> (timestamp: String?, tokens: Int)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let tokens = (usage["input_tokens"] as? Int ?? 0)
            + (usage["output_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        return (obj["timestamp"] as? String, tokens)
    }
}

/// Incremental transcript reader. Each refresh only consumes bytes appended
/// since the previous scan and keeps timestamped token samples for the rolling
/// window, avoiding repeated full-file reads as transcripts grow.
private actor QuotaScanner {
    private struct FileState {
        var offset: UInt64 = 0
        var remainder = Data()
        var samples: [QuotaUsageSample] = []
    }

    private var files: [URL: FileState] = [:]
    private let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plainISO = ISO8601DateFormatter()

    func total(in directory: URL, since cutoff: Date) -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var seen = Set<URL>()
        var total = 0
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            if Task.isCancelled { return total }
            seen.insert(url)
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { continue }

            let modified = values.contentModificationDate ?? .distantPast
            guard modified >= cutoff else {
                files.removeValue(forKey: url)
                continue
            }

            var state = files[url] ?? FileState()
            let size = UInt64(max(values.fileSize ?? 0, 0))
            if size < state.offset {
                // Rotation or truncation: rebuild this file's cache.
                state = FileState()
            }
            if size > state.offset {
                readAppendedBytes(from: url, fallbackDate: modified, into: &state)
            }
            state.samples.removeAll { $0.date < cutoff }
            total += state.samples.reduce(0) { $0 + $1.tokens }
            files[url] = state
        }

        files = files.filter { seen.contains($0.key) }
        return total
    }

    private func readAppendedBytes(
        from url: URL,
        fallbackDate: Date,
        into state: inout FileState
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.offset)
            guard let chunk = try handle.readToEnd(), !chunk.isEmpty else { return }
            state.offset += UInt64(chunk.count)

            var data = state.remainder
            data.append(chunk)
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            if data.last == 0x0A {
                state.remainder = Data()
            } else if let partial = lines.popLast() {
                state.remainder = Data(partial)
            }

            for line in lines where !line.isEmpty {
                guard let fields = QuotaUsageParser.fields(from: Data(line)) else { continue }
                let date = fields.timestamp.flatMap {
                    fractionalISO.date(from: $0) ?? plainISO.date(from: $0)
                } ?? fallbackDate
                state.samples.append(QuotaUsageSample(date: date, tokens: fields.tokens))
            }
        } catch {
            return
        }
    }
}

/// Unified Codex + Claude quota service.
///
/// Codex comes from the official App Server rate-limit API. Claude arrives
/// through Claude Code's official status-line JSON. The transcript scanner is
/// retained only as a local activity counter; it is never presented as an
/// authoritative plan percentage.
@MainActor
@Observable
final class QuotaService {
    private(set) var codexQuota = ProviderQuota.loading(.codex)
    private(set) var claudeQuota = ProviderQuota(
        provider: .claude,
        state: .waiting("Run a Claude prompt"),
        windows: [],
        planName: nil,
        creditsBalance: nil,
        resetCredits: nil,
        lastUpdated: nil
    )
    private(set) var tokensInWindow = 0
    private(set) var lastUpdated = Date.distantPast

    /// Configurable soft ceiling for the 5h window (used for the bar %).
    var windowLimit = 1_000_000

    private static let window: TimeInterval = 5 * 3600

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let scanner = QuotaScanner()
    @ObservationIgnored private let codexClient = CodexQuotaClient()
    @ObservationIgnored private let claudeClient = ClaudeUsageClient()
    @ObservationIgnored private var codexCallbacksConfigured = false

    private var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects")
    }

    private var claudeCacheURL: URL {
        AgentServer.supportDirectory.appending(path: "claude-quota.json")
    }

    var providers: [ProviderQuota] { [codexQuota, claudeQuota] }

    func start() {
        guard timer == nil else { return }
        configureCodexCallbacksIfNeeded()
        configureClaudeCallbacksIfNeeded()
        loadClaudeCache()
        codexClient.start()
        claudeClient.start()
        refresh()
        let timer = Timer(timeInterval: 180, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        codexClient.stop()
        claudeClient.stop()
    }

    var fraction: Double {
        guard windowLimit > 0 else { return 0 }
        return min(Double(tokensInWindow) / Double(windowLimit), 1)
    }

    func refresh() {
        codexClient.refresh()
        claudeClient.refresh()
        guard refreshTask == nil else { return }
        let cutoff = Date().addingTimeInterval(-Self.window)
        let directory = projectsDir
        refreshTask = Task { [weak self, scanner] in
            let total = await scanner.total(in: directory, since: cutoff)
            guard !Task.isCancelled, let self else { return }
            self.tokensInWindow = total
            self.lastUpdated = Date()
            self.refreshTask = nil
        }
    }

    func ingestClaude(
        _ rateLimits: ClaudeRateLimits,
        updatedAt: Date = .now,
        cached: Bool = false
    ) {
        let windows = rateLimits.normalizedWindows
        guard !windows.isEmpty else { return }
        claudeQuota = ProviderQuota(
            provider: .claude,
            state: cached ? .cached : .live,
            windows: windows,
            planName: nil,
            creditsBalance: nil,
            resetCredits: nil,
            lastUpdated: updatedAt
        )
    }

    private func configureCodexCallbacksIfNeeded() {
        guard !codexCallbacksConfigured else { return }
        codexCallbacksConfigured = true
        codexClient.onSnapshot = { [weak self] snapshot in
            self?.applyCodex(snapshot)
        }
        codexClient.onUnavailable = { [weak self] message in
            guard let self else { return }
            if self.codexQuota.windows.isEmpty {
                self.codexQuota.state = .unavailable(message)
            } else {
                self.codexQuota.state = .cached
            }
        }
    }

    private func configureClaudeCallbacksIfNeeded() {
        guard claudeClient.onLimits == nil else { return }
        claudeClient.onLimits = { [weak self] limits in
            self?.ingestClaude(limits, updatedAt: .now, cached: false)
        }
        claudeClient.onUnavailable = { [weak self] message in
            guard let self else { return }
            // Keep the last real numbers (as stale) rather than blanking them.
            if self.claudeQuota.windows.isEmpty {
                self.claudeQuota.state = .waiting(message)
            } else {
                self.claudeQuota.state = .cached
            }
        }
    }

    private func applyCodex(_ snapshot: CodexQuotaSnapshot) {
        let windows = snapshot.normalizedWindows
        guard !windows.isEmpty else {
            codexQuota.state = .unavailable("No subscription quota")
            return
        }
        codexQuota = ProviderQuota(
            provider: .codex,
            state: .live,
            windows: windows,
            planName: snapshot.planType.map(Self.displayPlan),
            creditsBalance: snapshot.creditsBalance,
            resetCredits: snapshot.resetCredits,
            lastUpdated: .now
        )
    }

    private func loadClaudeCache() {
        struct Cache: Decodable {
            let rateLimits: ClaudeRateLimits
            let updatedAt: Double?

            enum CodingKeys: String, CodingKey {
                case rateLimits = "rate_limits"
                case updatedAt = "quota_updated_at"
            }
        }
        guard let data = try? Data(contentsOf: claudeCacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data)
        else { return }
        ingestClaude(
            cache.rateLimits,
            updatedAt: cache.updatedAt.map(Date.init(timeIntervalSince1970:)) ?? .now,
            cached: true
        )
    }

    private static func displayPlan(_ raw: String) -> String {
        raw.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

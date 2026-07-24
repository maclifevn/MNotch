import Foundation
import Observation

/// Unified Codex + Claude quota service.
///
/// Codex comes from the official App Server rate-limit API. Claude is read from
/// the local Claude CLI. There is deliberately no transcript scan or status-line
/// hook: both were duplicate, non-authoritative sources of the same UI state.
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
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let codexClient = CodexQuotaClient()
    @ObservationIgnored private let claudeClient = ClaudeUsageClient()
    @ObservationIgnored private var codexCallbacksConfigured = false

    var providers: [ProviderQuota] { [codexQuota, claudeQuota] }

    func start() {
        guard timer == nil else { return }
        configureCodexCallbacksIfNeeded()
        configureClaudeCallbacksIfNeeded()
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
        codexClient.stop()
        claudeClient.stop()
    }

    func refresh(force: Bool = false) {
        codexClient.refresh()
        claudeClient.refresh(force: force)
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
        guard claudeClient.onWindows == nil else { return }
        claudeClient.onWindows = { [weak self] windows in
            self?.ingestClaudeWindows(windows)
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

    /// Claude usage straight from the `claude` CLI (`claude -p /usage`) — the
    /// session + weekly windows, no Keychain access involved.
    func ingestClaudeWindows(_ windows: [QuotaWindow], updatedAt: Date = .now) {
        guard !windows.isEmpty else { return }
        claudeQuota = ProviderQuota(
            provider: .claude,
            state: .live,
            windows: windows,
            planName: nil,
            creditsBalance: nil,
            resetCredits: nil,
            lastUpdated: updatedAt
        )
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

    private static func displayPlan(_ raw: String) -> String {
        raw.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

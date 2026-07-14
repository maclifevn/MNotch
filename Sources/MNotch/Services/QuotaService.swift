import Foundation
import Observation

/// Best-effort Claude usage estimate. Anthropic doesn't expose remaining plan
/// limits, so this sums token usage from ~/.claude transcripts over a rolling
/// 5-hour window (the same signal ccusage reads) and reports it against a
/// configurable ceiling. Clearly an estimate, not an official number.
@MainActor
@Observable
final class QuotaService {
    private(set) var tokensInWindow = 0
    private(set) var lastUpdated = Date.distantPast

    /// Configurable soft ceiling for the 5h window (used for the bar %).
    var windowLimit = 1_000_000

    private static let window: TimeInterval = 5 * 3600

    @ObservationIgnored private var timer: Timer?

    private var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects")
    }

    func start() {
        refresh()
        // Cheap enough every few minutes; transcripts are appended live.
        let timer = Timer(timeInterval: 180, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var fraction: Double {
        guard windowLimit > 0 else { return 0 }
        return min(Double(tokensInWindow) / Double(windowLimit), 1)
    }

    func refresh() {
        let cutoff = Date().addingTimeInterval(-Self.window)
        Task.detached(priority: .utility) { [projectsDir] in
            let total = Self.sumTokens(in: projectsDir, since: cutoff)
            await MainActor.run { [weak self] in
                self?.tokensInWindow = total
                self?.lastUpdated = Date()
            }
        }
    }

    /// Sum input+output+cache tokens from `usage` objects in every transcript
    /// line whose timestamp is within the window. Parsing is defensive: any
    /// malformed line is skipped.
    private nonisolated static func sumTokens(in dir: URL, since cutoff: Date) -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var total = 0
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            // Skip files untouched since the window opened.
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified < cutoff {
                continue
            }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if let ts = obj["timestamp"] as? String {
                    let date = iso.date(from: ts) ?? isoPlain.date(from: ts)
                    if let date, date < cutoff { continue }
                }
                guard let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { continue }
                // input + output + cache-creation only; cache reads are cheap
                // re-reads that dominate the raw sum and misrepresent usage.
                total += (usage["input_tokens"] as? Int ?? 0)
                total += (usage["output_tokens"] as? Int ?? 0)
                total += (usage["cache_creation_input_tokens"] as? Int ?? 0)
            }
        }
        return total
    }
}

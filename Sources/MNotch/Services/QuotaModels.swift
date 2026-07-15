import Foundation

enum QuotaProvider: String, CaseIterable, Sendable {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

enum QuotaConnectionState: Equatable, Sendable {
    case loading
    case live
    case cached
    case waiting(String)
    case unavailable(String)
}

struct QuotaWindow: Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var usedPercent: Double
    var durationMinutes: Int?
    var resetsAt: Date?

    var remainingPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }

    func merging(over older: QuotaWindow?) -> QuotaWindow {
        guard let older else { return self }
        let shouldKeepOlderLabel = durationMinutes == nil
            && older.durationMinutes != nil
        return QuotaWindow(
            id: id,
            label: label.isEmpty || shouldKeepOlderLabel ? older.label : label,
            usedPercent: usedPercent,
            durationMinutes: durationMinutes ?? older.durationMinutes,
            resetsAt: resetsAt ?? older.resetsAt
        )
    }

    static func durationLabel(minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080 * 7)d" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

struct ProviderQuota: Identifiable, Equatable, Sendable {
    var id: QuotaProvider { provider }
    let provider: QuotaProvider
    var state: QuotaConnectionState
    var windows: [QuotaWindow]
    var planName: String?
    var creditsBalance: String?
    var resetCredits: Int?
    var lastUpdated: Date?

    static func loading(_ provider: QuotaProvider) -> ProviderQuota {
        ProviderQuota(
            provider: provider,
            state: .loading,
            windows: [],
            planName: nil,
            creditsBalance: nil,
            resetCredits: nil,
            lastUpdated: nil
        )
    }

    var primaryWindow: QuotaWindow? { windows.first }
}

struct ClaudeQuotaWindow: Codable, Equatable, Sendable {
    let usedPercentage: Double
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

struct ClaudeRateLimits: Codable, Equatable, Sendable {
    let fiveHour: ClaudeQuotaWindow?
    let sevenDay: ClaudeQuotaWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    var normalizedWindows: [QuotaWindow] {
        var result: [QuotaWindow] = []
        if let fiveHour {
            result.append(QuotaWindow(
                id: "claude-five-hour",
                label: "5h",
                usedPercent: fiveHour.usedPercentage,
                durationMinutes: 300,
                resetsAt: fiveHour.resetsAt.map(Date.init(timeIntervalSince1970:))
            ))
        }
        if let sevenDay {
            result.append(QuotaWindow(
                id: "claude-seven-day",
                label: "7d",
                usedPercent: sevenDay.usedPercentage,
                durationMinutes: 10_080,
                resetsAt: sevenDay.resetsAt.map(Date.init(timeIntervalSince1970:))
            ))
        }
        return result
    }
}

struct CodexQuotaSnapshot: Equatable, Sendable {
    var primary: QuotaWindow?
    var secondary: QuotaWindow?
    var planType: String?
    var creditsBalance: String?
    var resetCredits: Int?
    var reachedType: String?

    func merging(over older: CodexQuotaSnapshot?) -> CodexQuotaSnapshot {
        guard let older else { return self }
        return CodexQuotaSnapshot(
            primary: primary.map { $0.merging(over: older.primary) } ?? older.primary,
            secondary: secondary.map { $0.merging(over: older.secondary) } ?? older.secondary,
            planType: planType ?? older.planType,
            creditsBalance: creditsBalance ?? older.creditsBalance,
            resetCredits: resetCredits ?? older.resetCredits,
            reachedType: reachedType ?? older.reachedType
        )
    }

    var normalizedWindows: [QuotaWindow] {
        [primary, secondary].compactMap { $0 }
    }
}

enum CodexQuotaParser {
    static func snapshot(from data: Data) -> CodexQuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let result = root["result"] as? [String: Any] {
            let rateLimits: [String: Any]?
            if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
               let codex = buckets["codex"] as? [String: Any] {
                rateLimits = codex
            } else {
                rateLimits = result["rateLimits"] as? [String: Any]
            }
            guard let rateLimits else { return nil }
            var snapshot = parseRateLimits(rateLimits)
            if let resets = result["rateLimitResetCredits"] as? [String: Any] {
                snapshot.resetCredits = integer(resets["availableCount"])
            }
            return snapshot
        }

        guard root["method"] as? String == "account/rateLimits/updated",
              let params = root["params"] as? [String: Any],
              let rateLimits = params["rateLimits"] as? [String: Any]
        else { return nil }
        return parseRateLimits(rateLimits)
    }

    private static func parseRateLimits(_ value: [String: Any]) -> CodexQuotaSnapshot {
        let credits = value["credits"] as? [String: Any]
        return CodexQuotaSnapshot(
            primary: parseWindow(value["primary"], id: "codex-primary", fallback: "Primary")
                ?? parseIndividualLimit(value["individualLimit"]),
            secondary: parseWindow(value["secondary"], id: "codex-secondary", fallback: "Secondary"),
            planType: value["planType"] as? String,
            creditsBalance: credits?["balance"] as? String,
            resetCredits: nil,
            reachedType: value["rateLimitReachedType"] as? String
        )
    }

    private static func parseWindow(
        _ raw: Any?,
        id: String,
        fallback: String
    ) -> QuotaWindow? {
        guard let raw = raw as? [String: Any],
              let used = number(raw["usedPercent"])
        else { return nil }
        let minutes = integer(raw["windowDurationMins"])
        let reset = number(raw["resetsAt"]).map(Date.init(timeIntervalSince1970:))
        return QuotaWindow(
            id: id,
            label: QuotaWindow.durationLabel(minutes: minutes, fallback: fallback),
            usedPercent: used,
            durationMinutes: minutes,
            resetsAt: reset
        )
    }

    private static func parseIndividualLimit(_ raw: Any?) -> QuotaWindow? {
        guard let raw = raw as? [String: Any],
              let remaining = number(raw["remainingPercent"])
        else { return nil }
        return QuotaWindow(
            id: "codex-individual-limit",
            label: "Budget",
            usedPercent: 100 - remaining,
            durationMinutes: nil,
            resetsAt: number(raw["resetsAt"]).map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
    }

    private static func integer(_ raw: Any?) -> Int? {
        number(raw).map(Int.init)
    }
}

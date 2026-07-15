import SwiftUI

/// The usage header atop the Agent panel: one compact line per provider that
/// has real data (Claude and/or Codex), so a user of both sees both at a
/// glance. Falls back to a single explanatory line when nothing is available.
struct AgentUsageHeader: View {
    let claude: ProviderQuota
    let codex: ProviderQuota

    var body: some View {
        let withData = [claude, codex].filter { !$0.windows.isEmpty }
        VStack(alignment: .leading, spacing: 5) {
            if withData.isEmpty {
                AgentUsageStrip(quota: claude)   // shows the "why it's empty" message
            } else {
                ForEach(withData) { AgentUsageStrip(quota: $0) }
            }
        }
    }
}

/// Compact one-line quota readout — "✦ 5h 11% 4h1m | 7d 2% 6h1m". Provider
/// glyph, then each rolling window as label · used% · time-to-reset.
struct AgentUsageStrip: View {
    let quota: ProviderQuota

    private var accent: Color {
        switch quota.provider {
        case .codex: Color(red: 0.26, green: 0.75, blue: 1.0)
        case .claude: Color(red: 0.95, green: 0.62, blue: 0.40)
        }
    }

    private var symbol: String {
        switch quota.provider {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkles"
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)

                let windows = Array(quota.windows.prefix(2))
                if windows.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.32))
                        .lineLimit(1)
                } else {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        if index > 0 {
                            Text("|")
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(.white.opacity(0.18))
                        }
                        windowView(window, now: context.date)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func windowView(_ window: QuotaWindow, now: Date) -> some View {
        HStack(spacing: 5) {
            Text(window.label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.82))
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(usageColor(window.usedPercent))
            if let reset = resetText(window.resetsAt, now: now) {
                Text(reset)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.34))
            }
        }
    }

    private var placeholder: String {
        // Prefer the live reason (e.g. "Sign in to Claude Code for usage") over
        // a generic fallback so the strip explains why it's empty.
        switch quota.state {
        case .waiting(let message), .unavailable(let message):
            return message
        case .loading:
            return "Loading usage…"
        default:
            break
        }
        switch quota.provider {
        case .claude: return "Claude usage unavailable"
        case .codex: return "Codex usage unavailable"
        }
    }

    /// Green while there's plenty of headroom, amber past half, red near the cap.
    private func usageColor(_ used: Double) -> Color {
        switch used {
        case ..<60: Color(red: 0.40, green: 0.85, blue: 0.52)
        case ..<85: Color(red: 0.98, green: 0.75, blue: 0.35)
        default: Color(red: 1.0, green: 0.45, blue: 0.42)
        }
    }

    private func resetText(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = max(Int(date.timeIntervalSince(now)), 0)
        let minutes = seconds / 60
        if minutes >= 1_440 { return "\(minutes / 1_440)d\((minutes % 1_440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h\(minutes % 60)m" }
        return minutes <= 0 ? "now" : "\(minutes)m"
    }
}

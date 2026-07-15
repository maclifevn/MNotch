import SwiftUI

/// Compact one-line quota readout pinned to the top of the Agent panel —
/// "✦ 5h 11% 4h1m | 7d 2% 6h1m". Mirrors the reference: provider glyph, then
/// each rolling window as label · used% · time-to-reset.
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
        switch quota.provider {
        case .claude: "Claude usage — run a prompt"
        case .codex: "Codex usage unavailable"
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

import SwiftUI

/// The usage header pinned atop the Agent panel: a tidy, column-aligned
/// micro-dashboard with one stable row per provider. Windows are bucketed
/// into short (5h) / long (7d) slots by duration, so every provider's bars line
/// up in the same columns instead of reading as ragged text lines. Falls back to
/// an inline status when a provider is still loading or temporarily unavailable.
struct AgentUsageHeader: View {
    let claude: ProviderQuota
    let codex: ProviderQuota

    /// A fixed column for aligning windows across providers, keyed on duration
    /// rather than label so Codex's "Primary"/"Budget" labels still line up with
    /// Claude's "5h"/"7d".
    private enum Slot: CaseIterable { case short, long }

    private var providers: [ProviderQuota] { [claude, codex] }

    /// A provider's window for a slot: short = a sub-day rolling window,
    /// long = a multi-day (or open-ended, e.g. a credit budget) window.
    private func window(_ provider: ProviderQuota, in slot: Slot) -> QuotaWindow? {
        provider.windows.first { window in
            switch slot {
            case .short: return (window.durationMinutes ?? .max) < 1_440
            case .long: return (window.durationMinutes ?? .max) >= 1_440
            }
        }
    }

    /// Only render slots at least one provider actually fills.
    private var activeSlots: [Slot] {
        Slot.allCases.filter { slot in
            providers.contains { window($0, in: slot) != nil }
        }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.085), lineWidth: 1)
                    )
            )
    }

    @ViewBuilder
    private var content: some View {
        let slots = activeSlots
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(providers) { provider in
                    HStack(spacing: 8) {
                        UsageProviderBadge(provider: provider.provider)
                            .frame(width: 62, alignment: .leading)
                        if provider.windows.isEmpty {
                            Text(stateMessage(provider))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.34))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(slots, id: \.self) { slot in
                                UsageWindowCell(window: window(provider, in: slot), now: context.date)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }

    private func stateMessage(_ quota: ProviderQuota) -> String {
        switch quota.state {
        case .waiting(let text), .unavailable(let text):
            return L10n.string(text)
        case .loading:
            return L10n.string("Loading usage…")
        case .live, .cached:
            switch quota.provider {
            case .claude: return L10n.string("Claude usage unavailable")
            case .codex: return L10n.string("Codex usage unavailable")
            }
        }
    }
}

/// Provider glyph + name anchoring the left of each row. The Grid sizes this
/// column to the widest badge so "Claude" and "Codex" align.
private struct UsageProviderBadge: View {
    let provider: QuotaProvider

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: provider.glyph)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(provider.accentColor)
                .frame(width: 13)
            Text(provider.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize()
        }
    }
}

/// One rolling window as `label · flexible bar · left% · reset`. The bar absorbs
/// spare width, keeping both two-window Claude rows and one-window Codex rows
/// balanced without wrapping the percentage at 100%.
private struct UsageWindowCell: View {
    let window: QuotaWindow?
    let now: Date

    private let labelWidth: CGFloat = 18
    private let barHeight: CGFloat = 5
    private let percentWidth: CGFloat = 54
    private let resetWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: 6) {
            Text(window.map { L10n.string($0.label) } ?? "")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: labelWidth, alignment: .leading)

            if let window {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.12))
                        Capsule(style: .continuous)
                            .fill(color(window))
                            .frame(width: fillWidth(window, available: geometry.size.width))
                    }
                }
                .frame(minWidth: 28, maxWidth: .infinity)
                .frame(height: barHeight)
                Text(String(
                    format: L10n.string("%d%% left"),
                    remainingInt(window)
                ))
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(color(window))
                    .frame(width: percentWidth, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)
                Text(resetText(window) ?? "")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.32))
                    .frame(width: resetWidth, alignment: .trailing)
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.16))
                    .frame(minWidth: 28, maxWidth: .infinity, alignment: .center)
                Color.clear.frame(width: percentWidth, height: barHeight)
                Color.clear.frame(width: resetWidth, height: barHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let window else { return L10n.string("no data") }
        let reset = resetText(window).map {
            String(format: L10n.string(", resets in %@"), $0)
        } ?? ""
        return String(
            format: L10n.string("%@ %d percent remaining%@"),
            window.label,
            remainingInt(window),
            reset
        )
    }

    private func remainingInt(_ window: QuotaWindow) -> Int {
        Int(window.remainingPercent.rounded())
    }

    /// Zero stays empty; anything above keeps a thin sliver so tiny usage is
    /// visible without overstating it.
    private func fillWidth(_ window: QuotaWindow, available: CGFloat) -> CGFloat {
        let fraction = window.remainingPercent / 100
        return fraction <= 0 ? 0 : min(available, max(2.5, available * fraction))
    }

    /// Remaining quota is the product promise: green with headroom, red near 0.
    private func color(_ window: QuotaWindow) -> Color {
        switch window.remainingPercent {
        case ..<15: Color(red: 1.0, green: 0.45, blue: 0.42)
        case ..<40: Color(red: 0.98, green: 0.75, blue: 0.35)
        default: Color(red: 0.40, green: 0.85, blue: 0.52)
        }
    }

    private func resetText(_ window: QuotaWindow) -> String? {
        guard let date = window.resetsAt else { return nil }
        let minutes = max(Int(date.timeIntervalSince(now) / 60), 0)
        if minutes <= 0 { return L10n.string("now") }
        if minutes >= 1_440 { return "\(minutes / 1_440)d\((minutes % 1_440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h\(minutes % 60)m" }
        return "\(minutes)m"
    }
}

private extension QuotaProvider {
    var accentColor: Color {
        switch self {
        case .codex: Color(red: 0.26, green: 0.75, blue: 1.0)
        case .claude: Color(red: 0.95, green: 0.62, blue: 0.40)
        }
    }

    var glyph: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkles"
        }
    }
}

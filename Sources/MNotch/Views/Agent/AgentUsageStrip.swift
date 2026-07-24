import SwiftUI

/// The usage header pinned atop the Agent panel: a tidy, column-aligned
/// micro-dashboard with one row per provider that has data. Windows are bucketed
/// into short (5h) / long (7d) slots by duration, so every provider's bars line
/// up in the same columns instead of reading as ragged text lines. Falls back to
/// a single dim explanatory line when nothing is available.
struct AgentUsageHeader: View {
    let claude: ProviderQuota
    let codex: ProviderQuota

    /// A fixed column for aligning windows across providers, keyed on duration
    /// rather than label so Codex's "Primary"/"Budget" labels still line up with
    /// Claude's "5h"/"7d".
    private enum Slot: CaseIterable { case short, long }

    private var providersWithData: [ProviderQuota] {
        [claude, codex].filter { !$0.windows.isEmpty }
    }

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
            providersWithData.contains { window($0, in: slot) != nil }
        }
    }

    var body: some View {
        content
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
        if providersWithData.isEmpty {
            UsageEmptyRow(quota: emptyStateQuota)
        } else {
            let slots = activeSlots
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 8) {
                    ForEach(providersWithData) { provider in
                        GridRow {
                            UsageProviderBadge(provider: provider.provider)
                                .gridColumnAlignment(.leading)
                            ForEach(slots, id: \.self) { slot in
                                UsageWindowCell(window: window(provider, in: slot), now: context.date)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Prefer a provider that carries an explanatory message so the fallback
    /// line says *why* it's empty rather than a generic string.
    private var emptyStateQuota: ProviderQuota {
        for quota in [claude, codex] {
            switch quota.state {
            case .waiting, .unavailable, .loading: return quota
            case .live, .cached: break
            }
        }
        return claude
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

/// One rolling window as an aligned quartet: `label · slim bar · left% · reset`,
/// each on a fixed rhythm so numbers and countdowns form clean vertical columns.
/// A nil window renders a dim placeholder at the same widths, so a provider that
/// lacks a slot keeps the table aligned instead of leaving a ragged void.
private struct UsageWindowCell: View {
    let window: QuotaWindow?
    let now: Date

    private let labelWidth: CGFloat = 16
    private let barWidth: CGFloat = 30
    private let barHeight: CGFloat = 5
    private let percentWidth: CGFloat = 48
    private let resetWidth: CGFloat = 38

    var body: some View {
        HStack(spacing: 6) {
            Text(window?.label ?? "")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: labelWidth, alignment: .leading)

            if let window {
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.12))
                        .frame(width: barWidth, height: barHeight)
                    Capsule(style: .continuous)
                        .fill(color(window))
                        .frame(width: fillWidth(window), height: barHeight)
                }
                Text("\(remainingInt(window))% left")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(color(window))
                    .frame(width: percentWidth, alignment: .trailing)
                Text(resetText(window) ?? "")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.32))
                    .frame(width: resetWidth, alignment: .trailing)
            } else {
                Text("—")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.16))
                    .frame(width: barWidth, alignment: .center)
                Color.clear.frame(width: percentWidth, height: barHeight)
                Color.clear.frame(width: resetWidth, height: barHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let window else { return "no data" }
        let reset = resetText(window).map { ", resets in \($0)" } ?? ""
        return "\(window.label) \(remainingInt(window)) percent remaining\(reset)"
    }

    private func remainingInt(_ window: QuotaWindow) -> Int {
        Int(window.remainingPercent.rounded())
    }

    /// Zero stays empty; anything above keeps a thin sliver so tiny usage is
    /// visible without overstating it.
    private func fillWidth(_ window: QuotaWindow) -> CGFloat {
        let fraction = window.remainingPercent / 100
        return fraction <= 0 ? 0 : max(2.5, barWidth * fraction)
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
        if minutes <= 0 { return "now" }
        if minutes >= 1_440 { return "\(minutes / 1_440)d\((minutes % 1_440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h\(minutes % 60)m" }
        return "\(minutes)m"
    }
}

/// Single dim line when neither provider has usage yet — surfaces the live
/// state message (e.g. "Sign in to Claude Code for usage").
private struct UsageEmptyRow: View {
    let quota: ProviderQuota

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: quota.provider.glyph)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.3))
            Text(message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.34))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var message: String {
        switch quota.state {
        case .waiting(let text), .unavailable(let text):
            return text
        case .loading:
            return "Loading usage…"
        case .live, .cached:
            switch quota.provider {
            case .claude: return "Claude usage unavailable"
            case .codex: return "Codex usage unavailable"
            }
        }
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

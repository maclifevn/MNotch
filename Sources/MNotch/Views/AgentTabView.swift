import SwiftUI

/// Expanded Agent tab. Permission requests always take priority; otherwise it
/// becomes a compact quota dashboard with live Codex + Claude headroom.
struct AgentTabView: View {
    let viewModel: NotchViewModel
    private let agents = AppServices.shared.agents

    var body: some View {
        Group {
            if let pending = agents.firstPending, let request = pending.request {
                AgentRequestCard(
                    session: pending,
                    request: request,
                    agents: agents,
                    viewModel: viewModel
                )
                .frame(width: NotchViewModel.agentWidth(for: request.detail))
            } else {
                AgentQuotaDashboard(viewModel: viewModel, agents: agents)
                    .frame(width: NotchViewModel.agentDashboardWidth)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            viewModel.setAgentContentHeight(height)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct AgentQuotaDashboard: View {
    let viewModel: NotchViewModel
    let agents: AgentMonitorService
    private let quota = AppServices.shared.quota

    var body: some View {
        VStack(spacing: 9) {
            header
            HStack(spacing: 9) {
                QuotaProviderCard(quota: quota.codexQuota)
                QuotaProviderCard(quota: quota.claudeQuota)
            }
            sessionStrip
        }
        .padding(.top, viewModel.geometry.notchHeight - 2)
        .padding(.horizontal, 15)
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
            Text("USAGE PULSE")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.65)
                .foregroundStyle(.white.opacity(0.52))
            Spacer()
            Button { quota.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.44))
                    .frame(width: 22, height: 18)
                    .background(.white.opacity(0.055), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Refresh quota")
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var sessionStrip: some View {
        let visible = Array(agents.sessions.prefix(2))
        if visible.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green.opacity(0.8))
                Text("No active agents")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.43))
                Spacer()
                Text("AUTO · 3 MIN")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.24))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        } else {
            HStack(spacing: 7) {
                ForEach(visible) { session in
                    AgentSessionChip(session: session, agents: agents)
                }
                if agents.sessions.count > visible.count {
                    Text("+\(agents.sessions.count - visible.count)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 24, height: 28)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct QuotaProviderCard: View {
    let quota: ProviderQuota

    private var accent: Color {
        switch quota.provider {
        case .codex: Color(red: 0.26, green: 0.75, blue: 1.0)
        case .claude: Color(red: 0.93, green: 0.58, blue: 0.38)
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
            VStack(alignment: .leading, spacing: 7) {
                cardHeader(now: context.date)
                if let primary = quota.primaryWindow {
                    quotaBody(primary: primary, now: context.date)
                } else {
                    unavailableBody
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [accent.opacity(0.105), .white.opacity(0.035)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 13)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(accent.opacity(0.16), lineWidth: 0.8)
            )
        }
    }

    private func cardHeader(now: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 20, height: 20)
                .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 0) {
                Text(quota.provider.displayName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                if let plan = quota.planName {
                    Text(plan)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.33))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            statusBadge(now: now)
        }
    }

    @ViewBuilder
    private func quotaBody(primary: QuotaWindow, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(Self.percent(primary.remainingPercent))
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text("% LEFT")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.35)
                .foregroundStyle(.white.opacity(0.38))
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 1) {
                Text(primary.label.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(accent)
                Text(resetText(primary.resetsAt, now: now))
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.34))
            }
        }

        QuotaBar(value: primary.remainingPercent / 100, tint: accent)

        if let secondary = quota.windows.dropFirst().first {
            HStack(spacing: 6) {
                Text(secondary.label.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.36))
                    .frame(width: 18, alignment: .leading)
                QuotaBar(value: secondary.remainingPercent / 100, tint: accent.opacity(0.78))
                Text("\(Self.percent(secondary.remainingPercent))%")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.56))
                    .frame(width: 28, alignment: .trailing)
            }
        } else if let resets = quota.resetCredits, resets > 0 {
            HStack {
                Text("RESET")
                Spacer()
                Text("\(resets) READY")
            }
            .font(.system(size: 8, weight: .bold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.36))
        } else if let credits = quota.creditsBalance {
            HStack {
                Text("CREDITS")
                Spacer()
                Text(credits)
            }
            .font(.system(size: 8, weight: .bold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.36))
        }
    }

    private var unavailableBody: some View {
        HStack(spacing: 8) {
            switch quota.state {
            case .loading:
                ProgressView().controlSize(.small).tint(accent)
            case .waiting:
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(accent.opacity(0.75))
            default:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(stateMessage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                Text(quota.provider == .claude ? "Available after a reply" : "Uses your Codex login")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var stateMessage: String {
        switch quota.state {
        case .loading: "Connecting…"
        case .live, .cached: "Quota unavailable"
        case .waiting(let message), .unavailable(let message): message
        }
    }

    private func statusBadge(now: Date) -> some View {
        let status: (String, Color) = {
            if let updated = quota.lastUpdated,
               now.timeIntervalSince(updated) > 15 * 60 {
                return ("STALE", .yellow)
            }
            switch quota.state {
            case .live: return ("LIVE", .green)
            case .cached: return ("CACHED", .yellow)
            case .loading: return ("SYNC", accent)
            case .waiting: return ("WAIT", .white.opacity(0.35))
            case .unavailable: return ("OFF", .red.opacity(0.8))
            }
        }()
        return HStack(spacing: 3) {
            Circle().fill(status.1).frame(width: 4, height: 4)
            Text(status.0)
                .font(.system(size: 7, weight: .heavy))
                .tracking(0.3)
                .foregroundStyle(status.1)
        }
    }

    private func resetText(_ date: Date?, now: Date) -> String {
        guard let date else { return "rolling" }
        let seconds = max(Int(date.timeIntervalSince(now)), 0)
        let minutes = seconds / 60
        if minutes >= 1_440 { return "in \(minutes / 1_440)d \((minutes % 1_440) / 60)h" }
        if minutes >= 60 { return "in \(minutes / 60)h \(minutes % 60)m" }
        return minutes == 0 ? "resetting" : "in \(minutes)m"
    }

    private static func percent(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}

private struct QuotaBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.075))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

private struct AgentSessionChip: View {
    let session: AgentSession
    let agents: AgentMonitorService

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.folderName.isEmpty ? "Agent" : session.folderName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)
                Text(session.kind.uppercased())
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.28))
            }
            Spacer(minLength: 2)
            Button { agents.jump(session) } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch session.status {
        case .working: .green
        case .waiting: .orange
        case .done: .white.opacity(0.3)
        }
    }
}

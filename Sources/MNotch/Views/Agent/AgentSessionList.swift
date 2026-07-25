import SwiftUI

/// Idle Agent view (no pending approval): the most recent session as a rich
/// card, older ones as compact rows — VibeIsland-style. Each carries the
/// agent/terminal/age tags and jumps to its terminal on tap.
struct AgentSessionList: View {
    let agents: AgentMonitorService

    private var ordered: [AgentSession] {
        agents.sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let sessions = ordered
            if sessions.isEmpty {
                emptyState
            } else {
                VStack(spacing: 6) {
                    SessionCard(session: sessions[0], agents: agents, now: context.date, featured: true)
                    ForEach(sessions.dropFirst().prefix(3)) { session in
                        SessionCard(session: session, agents: agents, now: context.date, featured: false)
                    }
                    if sessions.count > 4 {
                        Text(String(
                            format: L10n.string("+%d more"),
                            sessions.count - 4
                        ))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green.opacity(0.75))
            Text("No active agents")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
            Text("Waiting for a request")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.24))
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One session row: featured cards add a subtitle + status/jump line.
private struct SessionCard: View {
    let session: AgentSession
    let agents: AgentMonitorService
    let now: Date
    let featured: Bool

    var body: some View {
        Button {
            agents.jump(session)
        } label: {
            VStack(alignment: .leading, spacing: featured ? 5 : 0) {
                HStack(spacing: 8) {
                    avatar
                    Text(title)
                        .font(.system(size: featured ? 13 : 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(featured ? 0.95 : 0.8))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    tags
                }
                if featured {
                    if !session.lastMessage.isEmpty {
                        Text(session.lastMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .padding(.leading, 30)
                    }
                    HStack(spacing: 4) {
                        Text(statusText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(statusColor)
                        if session.status == .done {
                            Text("— click to jump")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(statusColor.opacity(0.8))
                        }
                    }
                    .padding(.leading, 30)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, featured ? 10 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .white.opacity(featured ? 0.06 : 0.03),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
        .buttonStyle(.plain)
    }

    private var avatar: some View {
        Group {
            if featured {
                Image(systemName: kindGlyph)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(kindColor)
                    .frame(width: 22, height: 22)
                    .background(kindColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            } else {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                    .frame(width: 22, alignment: .center)
            }
        }
    }

    private var tags: some View {
        HStack(spacing: 5) {
            tag(session.kind.capitalized, filled: true)
            if let terminal = terminalName { tag(terminal, filled: false) }
            Text(age)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.32))
        }
    }

    private func tag(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(filled ? 0.7 : 0.5))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(filled ? 0.09 : 0.05), in: Capsule())
    }

    private var title: String {
        session.folderName.isEmpty ? L10n.string("Agent") : session.folderName
    }

    private var kindColor: Color {
        switch session.kind.lowercased() {
        case "claude": Color(red: 0.95, green: 0.62, blue: 0.40)
        case "codex": Color(red: 0.26, green: 0.75, blue: 1.0)
        case "gemini": Color(red: 0.55, green: 0.78, blue: 0.55)
        default: .white.opacity(0.6)
        }
    }

    private var kindGlyph: String {
        switch session.kind.lowercased() {
        case "claude": "sparkles"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "gemini": "diamond.fill"
        default: "terminal.fill"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .working: Color(red: 0.40, green: 0.85, blue: 0.52)
        case .waiting: .orange
        case .done: Color(red: 0.40, green: 0.85, blue: 0.52)
        }
    }

    private var statusText: String {
        switch session.status {
        case .working: L10n.string("Working…")
        case .waiting: L10n.string("Waiting for you")
        case .done: L10n.string("Done")
        }
    }

    private var terminalName: String? {
        switch session.terminal.program {
        case "iTerm.app": "iTerm"
        case "Apple_Terminal": "Terminal"
        case "ghostty": "Ghostty"
        case "WarpTerminal": "Warp"
        case "vscode": "VS Code"
        case "WezTerm": "WezTerm"
        case "Hyper": "Hyper"
        case "codex": nil
        case .some(let other) where !other.isEmpty: other
        default: nil
        }
    }

    private var age: String {
        let seconds = max(Int(now.timeIntervalSince(session.lastActivity)), 0)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

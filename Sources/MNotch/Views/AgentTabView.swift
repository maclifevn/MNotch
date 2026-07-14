import SwiftUI

/// Expanded Agent tab: a pending permission request front-and-center with
/// Approve/Reject + plan preview, or the list of active sessions.
struct AgentTabView: View {
    let viewModel: NotchViewModel
    let agents = AppServices.shared.agents

    var body: some View {
        Group {
            if let pending = agents.firstPending {
                RequestView(session: pending, agents: agents)
            } else if agents.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .padding(.top, viewModel.geometry.notchHeight - 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.35))
            Text("No active agents")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        VStack(spacing: 6) {
            ForEach(agents.sessions) { session in
                SessionRow(session: session, agents: agents)
            }
        }
    }
}

/// A single session line: status dot, project, last message, jump button.
private struct SessionRow: View {
    let session: AgentSession
    let agents: AgentMonitorService

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.folderName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !session.lastMessage.isEmpty {
                    Text(session.lastMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button {
                agents.jump(session)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            if session.status == .done {
                Button {
                    agents.dismissDone(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    private var statusColor: Color {
        switch session.status {
        case .working: .green
        case .waiting: .orange
        case .done: .white.opacity(0.4)
        }
    }
}

/// A pending permission request with Approve / Reject and a plan preview.
private struct RequestView: View {
    let session: AgentSession
    let agents: AgentMonitorService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(session.folderName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Button { agents.jump(session) } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }

            if let request = session.request {
                Text(request.toolSummary)
                    .font(.system(size: 11, weight: .medium).monospaced())
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !request.markdown.isEmpty {
                    ScrollView {
                        Text(Self.rendered(request.markdown))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.75))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 60)
                }
            }

            HStack(spacing: 8) {
                Button {
                    agents.reject(session)
                } label: {
                    Text("Reject")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    agents.approve(session)
                } label: {
                    Text("Approve")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.green.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Lightweight Markdown → AttributedString (headings/bold/lists/code).
    static func rendered(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: markdown, options: options) {
            return attributed
        }
        return AttributedString(markdown)
    }
}

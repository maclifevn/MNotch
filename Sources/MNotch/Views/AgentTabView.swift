import SwiftUI

/// Expanded Agent tab: a pending permission request front-and-center with
/// Approve/Reject + plan preview, or the list of active sessions.
struct AgentTabView: View {
    let viewModel: NotchViewModel
    let agents = AppServices.shared.agents

    var body: some View {
        if let pending = agents.firstPending, let req = pending.request {
            // Content-sized: the card reports its ideal height (independent of
            // any imposed frame via .fixedSize) which drives the panel height.
            AgentRequestCard(session: pending, request: req, agents: agents, viewModel: viewModel)
                .frame(width: NotchViewModel.agentWidth(for: req.detail))
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    viewModel.setAgentContentHeight(h)
                }
                .frame(maxWidth: .infinity, alignment: .top)
        } else if agents.sessions.isEmpty {
            emptyState
        } else {
            sessionList
        }
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
        .padding(.top, viewModel.geometry.notchHeight - 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        VStack(spacing: 6) {
            ForEach(agents.sessions) { session in
                SessionRow(session: session, agents: agents)
            }
        }
        .padding(.top, viewModel.geometry.notchHeight - 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

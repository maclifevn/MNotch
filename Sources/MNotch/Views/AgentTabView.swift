import SwiftUI

/// Expanded Agent tab. A compact usage strip is always pinned on top; below it
/// sits either the pending permission request (approve/deny) or, when idle, the
/// recent-session list. The panel measures this content and springs to fit.
struct AgentTabView: View {
    let viewModel: NotchViewModel
    private let agents = AppServices.shared.agents
    private let quota = AppServices.shared.quota

    var body: some View {
        content
            .frame(width: contentWidth)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                viewModel.setAgentContentHeight(height)
            }
            .frame(maxWidth: .infinity, alignment: .top)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentUsageHeader(claude: quota.claudeQuota, codex: quota.codexQuota)
            if let pending = agents.firstPending, let request = pending.request {
                AgentRequestCard(
                    session: pending,
                    request: request,
                    agents: agents,
                    viewModel: viewModel
                )
            } else {
                AgentSessionList(agents: agents)
            }
        }
        .padding(.top, viewModel.geometry.notchHeight + 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 13)
    }

    private var contentWidth: CGFloat {
        if let request = agents.firstPending?.request {
            return NotchViewModel.agentWidth(for: request.detail)
        }
        return NotchViewModel.agentDashboardWidth
    }
}

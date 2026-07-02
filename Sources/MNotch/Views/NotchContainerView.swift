import SwiftUI

/// Root of the SwiftUI tree inside the panel. Fills the fixed panel size and
/// top-center-aligns the notch body.
struct NotchRootView: View {
    let viewModel: NotchViewModel

    var body: some View {
        NotchBodyView(viewModel: viewModel)
            .frame(
                width: NotchViewModel.panelSize.width,
                height: NotchViewModel.panelSize.height,
                alignment: .top
            )
            .ignoresSafeArea()
    }
}

/// The black notch shape plus whatever content the current state calls for.
struct NotchBodyView: View {
    let viewModel: NotchViewModel
    @Namespace private var notchSpace

    var body: some View {
        let size = viewModel.visualSize
        let shape = NotchShape(
            topRadius: viewModel.topRadius,
            bottomRadius: viewModel.bottomRadius
        )

        content
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(.black, in: shape)
            .clipShape(shape)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.status {
        case .closed, .hud, .pop:
            // Closed content (media compact chrome, HUD sliver, pops) lands in
            // later phases.
            Color.clear
        case .expanded:
            ExpandedView(viewModel: viewModel)
                .transition(Anim.contentSwap)
        }
    }
}

/// Placeholder expanded panel — replaced with real tabs (media, shelf,
/// calendar) in later phases.
struct ExpandedView: View {
    let viewModel: NotchViewModel

    var body: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 16)
                .fill(.white.opacity(0.1))
                .frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.15))
                    .frame(width: 140, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.08))
                    .frame(width: 90, height: 10)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, viewModel.geometry.notchHeight + 12)
        .padding(.bottom, 16)
    }
}

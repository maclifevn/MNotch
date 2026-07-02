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
    private let services = AppServices.shared
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
            .animation(Anim.open, value: viewModel.mediaActive)
            .onChange(of: services.media.hasActiveMedia, initial: true) {
                viewModel.mediaActive = services.media.hasActiveMedia
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.status {
        case .closed:
            if viewModel.mediaActive {
                MediaCompactView(
                    viewModel: viewModel,
                    media: services.media,
                    namespace: notchSpace
                )
                .transition(Anim.contentSwap)
            } else {
                Color.clear
            }
        case .pop(let kind):
            popView(kind)
                .transition(Anim.contentSwap)
        case .hud(let kind):
            HUDView(
                kind: kind,
                value: viewModel.hudValue,
                muted: viewModel.hudMuted,
                geometry: viewModel.geometry
            )
            .transition(Anim.contentSwap)
        case .expanded(let tab):
            expanded(tab)
                .transition(Anim.contentSwap)
        }
    }

    @ViewBuilder
    private func popView(_ kind: PopKind) -> some View {
        switch kind {
        case .charging(let percentage):
            BatteryPopView(percentage: percentage, low: false, geometry: viewModel.geometry)
        case .lowBattery(let percentage):
            BatteryPopView(percentage: percentage, low: true, geometry: viewModel.geometry)
        case .device(let name, let symbol, let battery):
            DevicePopView(name: name, symbol: symbol, battery: battery, geometry: viewModel.geometry)
        }
    }

    @ViewBuilder
    private func expanded(_ tab: NotchTab) -> some View {
        switch tab {
        case .media:
            MediaExpandedView(
                viewModel: viewModel,
                media: services.media,
                audio: services.audio,
                namespace: notchSpace
            )
        case .shelf, .calendar:
            // Later phases.
            Color.clear
        }
    }
}

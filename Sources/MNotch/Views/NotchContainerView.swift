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
            .overlay {
                if SettingsStore.shared.contrastOutline {
                    shape
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                        .padding(.top, 1)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                viewModel.setPointerInside(inside)
            }
            .onTapGesture {
                viewModel.handleTap()
            }
            .animation(Anim.open, value: viewModel.mediaActive)
            .onChange(
                of: services.media.hasActiveMedia && SettingsStore.shared.mediaEnabled,
                initial: true
            ) { _, active in
                viewModel.mediaActive = active
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
                .overlay(alignment: .topTrailing) {
                    TabStrip(viewModel: viewModel, current: tab)
                }
                .transition(Anim.contentSwap)
        }
    }

    @ViewBuilder
    private func popView(_ kind: PopKind) -> some View {
        switch kind {
        case .charging(let percentage):
            BatteryPopView(percentage: percentage, kind: .charging, geometry: viewModel.geometry)
        case .lowBattery(let percentage):
            BatteryPopView(percentage: percentage, kind: .low, geometry: viewModel.geometry)
        case .lowPower(let on):
            BatteryPopView(
                percentage: AppServices.shared.power.percentage,
                kind: .lowPower(on: on),
                geometry: viewModel.geometry
            )
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
        case .shelf:
            ShelfView(viewModel: viewModel)
        case .calendar:
            CalendarStripView(viewModel: viewModel, calendar: services.calendar)
        }
    }
}

/// Tiny tab/settings icons in the expanded panel's top-right wing.
struct TabStrip: View {
    let viewModel: NotchViewModel
    let current: NotchTab
    private let settings = SettingsStore.shared

    var body: some View {
        HStack(spacing: 2) {
            tabButton(.media, symbol: "music.note")
            if settings.shelfEnabled {
                tabButton(.shelf, symbol: "tray.fill")
            }
            if settings.calendarEnabled {
                tabButton(.calendar, symbol: "calendar")
            }
            Button {
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 7)
        .padding(.trailing, 12)
    }

    private func tabButton(_ tab: NotchTab, symbol: String) -> some View {
        Button {
            viewModel.selectTab(tab)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(current == tab ? .white : .white.opacity(0.35))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(.white.opacity(current == tab ? 0.14 : 0))
                )
        }
        .buttonStyle(.plain)
    }
}

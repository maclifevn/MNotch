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
            .background {
                // Progressive blur: soft behind-window halo fading downward,
                // mounted only while expanded so the closed notch costs
                // nothing to composite.
                if viewModel.status.isExpanded, SettingsStore.shared.progressiveBlur {
                    VisualEffectView()
                        .frame(width: size.width + 70, height: size.height + 60)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black.opacity(0.5), location: 0.55),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .transition(.opacity)
                }
            }
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
            .animation(Anim.open, value: viewModel.resolvedIdle)
            .onChange(of: mediaVisible, initial: true) { _, active in
                viewModel.mediaActive = active
            }
            .onChange(of: services.media.playback.trackIdentity) {
                // Fresh content revives a swiped-away activity.
                viewModel.reviveActivity()
            }
            .onAppear {
                if SettingsStore.shared.idleActivity == .calendar
                    || SettingsStore.shared.idleActivity == .duo {
                    services.calendar.ensureStarted()
                }
            }
    }

    /// Media chrome shows when enabled, playing, and (optionally) the source
    /// app isn't frontmost.
    private var mediaVisible: Bool {
        let settings = SettingsStore.shared
        guard settings.mediaEnabled,
              services.media.idleVisible(after: settings.mediaIdleDuration)
        else { return false }
        if settings.mediaHideWhileSourceActive,
           services.occlusion.frontmostBundleID == services.media.playback.bundleIdentifier {
            return false
        }
        return true
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.status {
        case .closed:
            switch viewModel.resolvedIdle {
            case .playing:
                MediaCompactView(
                    viewModel: viewModel,
                    media: services.media,
                    namespace: notchSpace
                )
                .transition(Anim.contentSwap)
            case .calendar:
                CalendarCompactView(viewModel: viewModel, calendar: services.calendar)
                    .transition(Anim.contentSwap)
                    .onAppear { services.calendar.ensureStarted() }
            case .duo:
                DuoCompactView(
                    viewModel: viewModel,
                    media: services.media,
                    calendar: services.calendar
                )
                .transition(Anim.contentSwap)
            case .empty:
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
        case .focus(let name, let symbol, let on):
            FocusPopView(name: name, symbol: symbol, on: on, geometry: viewModel.geometry)
        case .event(let title, let red, let green, let blue, let startingNow, let start):
            EventPopView(
                title: title,
                color: Color(red: red, green: green, blue: blue),
                startingNow: startingNow,
                start: start,
                geometry: viewModel.geometry
            )
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

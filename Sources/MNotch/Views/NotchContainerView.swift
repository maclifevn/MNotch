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

    /// Every full panel uses the same wallpaper-independent dark float.
    /// Behind-window blur samples bright desktop content and creates a white
    /// halo, so it must never be used as the expanded surface shadow.
    private var usesFloatingSurfaceShadow: Bool {
        switch viewModel.status {
        case .expanded, .pop(.agentConfirm): true
        default: false
        }
    }

    var body: some View {
        let size = viewModel.visualSize
        let shape = NotchShape(
            topRadius: viewModel.topRadius,
            bottomRadius: viewModel.bottomRadius
        )

        content
            .frame(width: size.width, height: size.height, alignment: .top)
            // Opaque black notch: fill behind the content, clipped to the
            // shape so the interior always reads solid — never washed out.
            .background(.black, in: shape)
            .clipShape(shape)
            .background {
                if usesFloatingSurfaceShadow,
                   SettingsStore.shared.panelShadow {
                    // One shell for Music, Shelf, Calendar and Agent: the opaque
                    // notch casts a dark shadow without sampling the wallpaper.
                    shape.fill(.black)
                        .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 11)
                }
            }
            .overlay {
                if SettingsStore.shared.contrastOutline {
                    NotchOutlineShape(
                        topRadius: viewModel.topRadius,
                        bottomRadius: viewModel.bottomRadius
                    )
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.handleTap()
            }
            .animation(Anim.open, value: viewModel.mediaActive)
            .animation(Anim.open, value: viewModel.resolvedIdle)
            .animation(Anim.open, value: viewModel.pomodoroActive)
            .onChange(of: mediaVisible, initial: true) { _, active in
                viewModel.mediaActive = active
            }
            .onChange(of: services.pomodoro.isActive, initial: true) { _, active in
                viewModel.pomodoroActive = active
            }
            .onChange(of: services.media.playback.trackIdentity) {
                // Fresh content revives a swiped-away activity.
                viewModel.reviveActivity()
            }
            .onChange(of: SettingsStore.shared.mediaIdleDuration) { _, duration in
                services.media.scheduleIdleExpiry(after: duration)
            }
            .onAppear {
                if SettingsStore.shared.idleActivity == .calendar
                    || SettingsStore.shared.idleActivity == .duo {
                    services.calendar.ensureStarted()
                }
            }
            .onChange(of: enabledTabs) { _, tabs in
                guard case .expanded(let current) = viewModel.status,
                      !tabs.contains(current),
                      let fallback = tabs.first
                else { return }
                viewModel.selectTab(fallback)
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

    private var enabledTabs: [NotchTab] {
        NotchTab.allCases.filter(viewModel.isTabEnabled)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.status {
        case .closed:
            if viewModel.pomodoroActive {
                // A running Pomodoro session owns the closed wings.
                PomodoroCompactView(viewModel: viewModel, pomodoro: services.pomodoro)
                    .transition(Anim.contentSwap)
            } else {
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
        case .accessibility:
            AccessibilityPopView(geometry: viewModel.geometry)
        case .pomodoro(let title, let symbol, let detail):
            PomodoroPopView(
                title: title, symbol: symbol, detail: detail,
                geometry: viewModel.geometry
            )
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
                // Distinct identity per device+level: consecutive device pops
                // stay in the same structural branch, and without this the
                // ring's @State keeps the previous device's fill.
                .id("device-\(name)-\(battery ?? -1)")
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
        case .agent(let name, let kind, let needsInput):
            AgentPopView(name: name, kind: kind, needsInput: needsInput, geometry: viewModel.geometry)
        case .agentConfirm(let approved):
            AgentConfirmView(approved: approved, geometry: viewModel.geometry)
        }
    }

    private func expanded(_ tab: NotchTab) -> some View {
        Group {
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
            case .pomodoro:
                PomodoroTabView(viewModel: viewModel, pomodoro: services.pomodoro)
            case .agent:
                AgentTabView(viewModel: viewModel)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            viewModel.setExpandedContentHeight(height, for: tab)
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
            if viewModel.isTabEnabled(.media) {
                tabButton(.media, symbol: "music.note", label: "Now Playing")
            }
            if settings.shelfEnabled {
                tabButton(.shelf, symbol: "tray.fill", label: "File Tray")
            }
            if settings.calendarEnabled {
                tabButton(.calendar, symbol: "calendar", label: "Calendar")
            }
            if settings.pomodoroEnabled {
                tabButton(.pomodoro, symbol: "timer", label: "Pomodoro")
            }
            if settings.agentEnabled {
                tabButton(.agent, symbol: "terminal.fill", label: "Agents")
            }
            Button {
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("MNotch Settings")
            .accessibilityLabel("MNotch Settings")
        }
        .padding(.top, 7)
        .padding(.trailing, 12)
    }

    private func tabButton(_ tab: NotchTab, symbol: String, label: String) -> some View {
        Button {
            viewModel.selectTab(tab)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(current == tab ? .white : .white.opacity(0.35))
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(.white.opacity(current == tab ? 0.14 : 0))
                )
        }
        .buttonStyle(.plain)
        .help(L10n.string(label))
        .accessibilityLabel(L10n.string(label))
        .accessibilityAddTraits(current == tab ? .isSelected : [])
    }
}

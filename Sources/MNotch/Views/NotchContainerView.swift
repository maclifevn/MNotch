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
                .overlay(alignment: .topLeading) {
                    TabStrip(viewModel: viewModel, current: tab, side: .leading)
                }
                .overlay(alignment: .topTrailing) {
                    TabStrip(viewModel: viewModel, current: tab, side: .trailing)
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

/// Tab/settings icons flanking the notch in the expanded panel: the enabled
/// tabs split into a left and right group (gear always right-most) so neither
/// wing crowds, with comfortably large hit targets.
struct TabStrip: View {
    enum Side { case leading, trailing }

    let viewModel: NotchViewModel
    let current: NotchTab
    let side: Side
    private let settings = SettingsStore.shared

    static let buttonSize: CGFloat = 30
    private static let symbolSize: CGFloat = 12

    private struct Entry: Identifiable {
        let tab: NotchTab?          // nil = the Settings gear
        let symbol: String
        let label: String
        var id: String { label }
    }

    private var allEntries: [Entry] {
        var entries: [Entry] = []
        if viewModel.isTabEnabled(.media) {
            entries.append(Entry(tab: .media, symbol: "music.note", label: "Now Playing"))
        }
        if settings.shelfEnabled {
            entries.append(Entry(tab: .shelf, symbol: "tray.fill", label: "File Tray"))
        }
        if settings.calendarEnabled {
            entries.append(Entry(tab: .calendar, symbol: "calendar", label: "Calendar"))
        }
        if settings.pomodoroEnabled {
            entries.append(Entry(tab: .pomodoro, symbol: "timer", label: "Pomodoro"))
        }
        if settings.agentEnabled {
            entries.append(Entry(tab: .agent, symbol: "terminal.fill", label: "Agents"))
        }
        entries.append(Entry(tab: nil, symbol: "gearshape.fill", label: "MNotch Settings"))
        return entries
    }

    /// First half left of the notch, the rest (incl. gear) right — right-heavy
    /// on odd counts so Settings never migrates leftward.
    private var visibleEntries: [Entry] {
        let all = allEntries
        let leftCount = all.count / 2
        switch side {
        case .leading: return Array(all.prefix(leftCount))
        case .trailing: return Array(all.dropFirst(leftCount))
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(visibleEntries) { entry in
                button(entry)
            }
        }
        .padding(.top, 5)
        .padding(.leading, side == .leading ? 14 : 0)
        .padding(.trailing, side == .trailing ? 14 : 0)
    }

    private func button(_ entry: Entry) -> some View {
        Button {
            if let tab = entry.tab {
                viewModel.selectTab(tab)
            } else {
                SettingsWindowController.shared.show()
            }
        } label: {
            Image(systemName: entry.symbol)
                .font(.system(size: Self.symbolSize, weight: .semibold))
                .foregroundStyle(current == entry.tab ? .white : .white.opacity(0.4))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background(
                    Circle().fill(.white.opacity(current == entry.tab ? 0.14 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L10n.string(entry.label))
        .accessibilityLabel(L10n.string(entry.label))
        .accessibilityAddTraits(current == entry.tab ? .isSelected : [])
    }
}

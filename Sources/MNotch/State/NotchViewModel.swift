import SwiftUI

enum NotchTab: String, CaseIterable {
    case media
    case shelf
    case calendar
    case pomodoro
    case agent
}

enum HUDKind: Equatable {
    case volume
    case brightness
    case keyboardBacklight
}

enum PopKind: Equatable {
    case accessibility
    case charging(percentage: Int)
    case lowBattery(percentage: Int)
    case lowPower(on: Bool)
    case device(name: String, symbol: String, battery: Int?)
    case focus(name: String, symbol: String, on: Bool)
    case event(title: String, red: Double, green: Double, blue: Double, startingNow: Bool, start: Date)
    case agent(name: String, kind: String, needsInput: Bool)
    case agentConfirm(approved: Bool)
    case pomodoro(title: String, symbol: String, detail: String)
}

enum NotchStatus: Equatable {
    case closed
    case hud(HUDKind)
    case pop(PopKind)
    case expanded(NotchTab)

    var isExpanded: Bool {
        if case .expanded = self { return true }
        return false
    }
}

struct NotchIdleInputs: Equatable {
    let activity: IdleActivity
    let mostRecent: Bool
    let mediaAvailable: Bool
    let calendarAvailable: Bool
    let dismissed: Bool
}

enum NotchIdleResolver {
    static func resolve(_ input: NotchIdleInputs) -> NotchViewModel.ResolvedIdle {
        guard !input.dismissed else { return .empty }
        let choice: IdleActivity
        if input.mostRecent {
            choice = input.mediaAvailable
                ? .playing
                : (input.calendarAvailable ? .calendar : .none)
        } else {
            choice = input.activity
        }

        switch choice {
        case .none: return .empty
        case .playing: return input.mediaAvailable ? .playing : .empty
        case .calendar: return input.calendarAvailable ? .calendar : .empty
        case .duo:
            if input.mediaAvailable && input.calendarAvailable { return .duo }
            if input.mediaAvailable { return .playing }
            if input.calendarAvailable { return .calendar }
            return .empty
        }
    }
}

/// One state machine per notch panel. All animation quality routes through
/// here: every transition happens inside `withAnimation` with a shared spring
/// from `Anim`, and the view tree just renders `status`.
@MainActor
@Observable
final class NotchViewModel {
    let geometry: NotchGeometry

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    private(set) var status: NotchStatus = .closed
    var mediaActive = false
    private(set) var lastTab: NotchTab = .media

    // MARK: - Shape metrics

    var topRadius: CGFloat { status.isExpanded ? 12 : 6 }
    var bottomRadius: CGFloat { status.isExpanded ? 24 : 13 }

    /// What the closed notch is currently showing in its wings.
    enum ResolvedIdle: Equatable {
        case empty, playing, calendar, duo
    }

    /// Swipe-up dismissal hides the current activity until new content lands.
    private(set) var activityDismissed = false

    var resolvedIdle: ResolvedIdle {
        let settings = SettingsStore.shared
        let calendar = AppServices.shared.calendar
        let mediaOK = mediaActive
        var calendarOK = settings.calendarEnabled
            && calendar.authorized
            && (calendar.today.first != nil || calendar.upcoming.first != nil)
        if settings.calendarDisableDuringEvents, calendar.hasOngoingEvent {
            calendarOK = false
        }

        return NotchIdleResolver.resolve(NotchIdleInputs(
            activity: settings.idleActivity,
            mostRecent: settings.idleMostRecent,
            mediaAvailable: mediaOK,
            calendarAvailable: calendarOK,
            dismissed: activityDismissed
        ))
    }

    func dismissActivity() {
        withAnimation(Anim.close) { activityDismissed = true }
    }

    func reviveActivity() {
        guard activityDismissed else { return }
        withAnimation(Anim.open) { activityDismissed = false }
    }

    /// Horizontal swipe with no media: flip the idle activity choice.
    func cycleActivity() {
        let settings = SettingsStore.shared
        withAnimation(Anim.open) {
            settings.idleActivity = settings.idleActivity == .calendar ? .playing : .calendar
        }
    }

    /// Set from NotchBodyView while a Pomodoro session is active; the countdown
    /// takes over the closed wings for the session's duration.
    var pomodoroActive = false

    /// Extra width added to each side of the closed notch per activity.
    private var wingWidth: CGFloat {
        if pomodoroActive { return 46 }
        return switch resolvedIdle {
        case .empty: 0
        case .playing: 26
        case .calendar, .duo: 96
        }
    }

    /// Fixed content width inside a calendar/duo wing (wing minus padding),
    /// so wing content can never overflow into the camera cutout.
    var calendarWingContentWidth: CGFloat { 84 }

    /// Expanded tabs share a compact width, but their height follows their
    /// natural content instead of leaving a fixed black slab underneath.
    static let expandedWidth: CGFloat = 420

    /// The top-right tab strip lives in the notch band. On a physical notch a
    /// narrow panel would tuck its left-most tab (Now Playing) behind the
    /// cutout, so widen just enough that all tabs clear the notch's right edge.
    /// Fake-notch panels have no physical occlusion, so this stays 0 there.
    private var tabStripClearWidth: CGFloat {
        guard geometry.isPhysical else { return 0 }
        // A fifth tab (Pomodoro) widens the strip past the 320pt clearance.
        let extra: CGFloat = SettingsStore.shared.pomodoroEnabled ? 60 : 0
        return geometry.notchWidth + 320 + extra
    }
    static let expandedSeedHeights: [NotchTab: CGFloat] = [
        .media: 205,
        .shelf: 148,
        .calendar: 205,
        .pomodoro: 190,
    ]
    static let hudExtraWidth: CGFloat = 160
    static let hudExtraHeight: CGFloat = 10
    static let popExtraWidth: CGFloat = 190
    static let popExtraHeight: CGFloat = 6

    /// Fixed panel (window) size — never animated, big enough for max
    /// expansion (400 tall so a full-height agent diff + drop shadow render
    /// unclipped; interactiveRect uses visualSize so the extra canvas is
    /// invisible and non-interactive).
    static let panelSize = CGSize(width: 700, height: 448)

    // Agent panel: fixed per-detail width, MEASURED height.
    static let agentNarrowWidth: CGFloat = 380   // .generic
    static let agentWideWidth: CGFloat = 460     // everything else
    static let agentDashboardWidth: CGFloat = 468
    static let agentDashboardHeight: CGFloat = 190
    static let agentMinHeight: CGFloat = 92
    // Tall enough that a max-height diff/write preview plus the always-present
    // usage strip still leaves the Deny/Allow row inside the panel canvas.
    static let agentMaxHeight: CGFloat = 396

    /// Floor so the flared top edge always spans the physical cutout.
    var minAgentWidth: CGFloat { geometry.notchWidth + topRadius * 2 + 48 }

    static func agentWidth(for d: RequestDetail) -> CGFloat {
        if case .generic = d { return agentNarrowWidth }
        return agentWideWidth
    }

    /// Class-default seed so the open animation targets ~final height at once.
    /// Includes the always-present usage strip (~24pt) above the request card.
    static func seedHeight(for d: RequestDetail) -> CGFloat {
        switch d {
        case .generic: 150
        case .bash: 182
        case .write: 262
        case .edit, .multiEdit, .patch: 282
        case .plan: 272
        }
    }

    /// Live natural height of the agent card, measured from the view and fed
    /// back here. Epsilon-guarded so a sub-pixel delta can't re-spring forever.
    private(set) var agentContentHeight: CGFloat = 0
    private var expandedContentHeights: [NotchTab: CGFloat] = [:]

    func setAgentContentHeight(_ h: CGFloat) {
        let clamped = min(max(h, Self.agentMinHeight), Self.agentMaxHeight)
        guard abs(clamped - agentContentHeight) > 0.5 else { return }
        withAnimation(Anim.open) { agentContentHeight = clamped }
    }

    func setExpandedContentHeight(_ height: CGFloat, for tab: NotchTab) {
        guard tab != .agent else { return }
        let clamped = Self.clampedExpandedHeight(height, for: tab)
        guard abs(clamped - (expandedContentHeights[tab] ?? 0)) > 0.5 else { return }
        if status == .expanded(tab) {
            withAnimation(Anim.open) { expandedContentHeights[tab] = clamped }
        } else {
            expandedContentHeights[tab] = clamped
        }
    }

    static func clampedExpandedHeight(_ height: CGFloat, for tab: NotchTab) -> CGFloat {
        let range: ClosedRange<CGFloat> = switch tab {
        case .media: 176...240
        case .shelf: 124...220
        case .calendar: 132...310
        case .pomodoro: 150...240
        case .agent: 0...0
        }
        return min(max(height, range.lowerBound), range.upperBound)
    }

    var agentConfirmSize: CGSize {
        CGSize(
            width: max(minAgentWidth, geometry.notchWidth + 150),
            height: geometry.notchHeight + 36
        )
    }

    /// Hover apron: interactive region extends this far past the visible shape.
    static let apron: CGFloat = 8

    /// Subtle growth while hovering the closed notch (Alcove-style feedback);
    /// expanding requires a click.
    static let hoverGrowth = CGSize(width: 18, height: 4)

    var closedSize: CGSize {
        CGSize(
            width: geometry.notchWidth + topRadius * 2 + wingWidth * 2,
            height: geometry.notchHeight
        )
    }

    var visualSize: CGSize {
        switch status {
        case .closed:
            var size = closedSize
            if isHovering {
                size.width += Self.hoverGrowth.width
                size.height += Self.hoverGrowth.height
            }
            return size
        case .hud:
            return CGSize(
                width: closedSize.width + Self.hudExtraWidth,
                height: closedSize.height + Self.hudExtraHeight
            )
        case .pop(.agentConfirm):
            return agentConfirmSize
        case .pop:
            return CGSize(
                width: closedSize.width + Self.popExtraWidth,
                height: closedSize.height + Self.popExtraHeight
            )
        case .expanded(let tab):
            guard tab == .agent else {
                return CGSize(
                    width: max(Self.expandedWidth, tabStripClearWidth),
                    height: expandedContentHeights[tab]
                        ?? Self.expandedSeedHeights[tab]
                        ?? 205
                )
            }
            let request = AppServices.shared.agents.firstPending?.request
            let seed = request.map { Self.seedHeight(for: $0.detail) }
                ?? Self.agentDashboardHeight
            let width = request.map { Self.agentWidth(for: $0.detail) }
                ?? Self.agentDashboardWidth
            let h = agentContentHeight == 0
                ? seed
                : min(max(agentContentHeight, Self.agentMinHeight), Self.agentMaxHeight)
            return CGSize(width: max(width, minAgentWidth), height: h)
        }
    }

    /// Interactive bounds for `NotchHostingView.hitTest`, in that view's
    /// coordinates. NSHostingView is FLIPPED (origin top-left, like SwiftUI),
    /// so the notch region hugs y = 0. Slightly larger than the visible shape
    /// so tiny pointer overshoots don't collapse the panel.
    func interactiveRect(in bounds: CGRect, flipped: Bool) -> CGRect {
        let size = visualSize
        let width = size.width + Self.apron * 2
        let height = size.height + Self.apron
        return CGRect(
            x: (bounds.width - width) / 2,
            y: flipped ? 0 : bounds.height - height,
            width: width,
            height: height
        )
    }

    // MARK: - Hover intent
    //
    // Alcove behavior: hovering only grows the closed notch slightly; a click
    // opens the expanded panel; moving the pointer away closes it.

    static let closeDelay: Duration = .milliseconds(350)

    private(set) var isHovering = false
    private var pointerInside = false
    private var hoverTask: Task<Void, Never>?

    func setPointerInside(_ inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverTask?.cancel()

        withAnimation(inside ? Anim.open : Anim.close) { isHovering = inside }

        if inside, SettingsStore.shared.expandOnHover, !status.isExpanded {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, self.pointerInside else { return }
                self.expand(self.lastTab)
            }
        }

        if !inside, status.isExpanded {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: Self.closeDelay)
                guard !Task.isCancelled, let self, !self.pointerInside else { return }
                // Keep the Agent tab pinned open while a permission request is
                // pending — it needs an approve/reject, not an auto-close.
                if self.status == .expanded(.agent),
                   AppServices.shared.agents.hasPendingRequest {
                    return
                }
                self.collapse()
            }
        }
    }

    /// Open the Agent tab for a permission request; stays open (sticky) until
    /// the request is answered. Seeds the height to the detail's default so
    /// the open animation targets ~final size in one step.
    func openAgentRequest() {
        lastTab = .agent
        let seed = AppServices.shared.agents.firstPending?.request
            .map { Self.seedHeight(for: $0.detail) } ?? Self.agentMinHeight
        withAnimation(Anim.open) {
            agentContentHeight = seed
            status = .expanded(.agent)
        }
    }

    /// After Approve/Reject: show a compact confirmation pill for 1.2s. Set
    /// BEFORE responding so the synchronous collapseAgentIfIdle no-ops (its
    /// guard checks `status == .expanded(.agent)`, already replaced here).
    func confirmAgentDecision(approved: Bool) {
        // A pending hover-exit close task would otherwise collapse the pill.
        hoverTask?.cancel()
        popDismissTask?.cancel()
        withAnimation(Anim.pop) { status = .pop(.agentConfirm(approved: approved)) }
        popDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            if case .pop(.agentConfirm) = self.status {
                withAnimation(Anim.close) { self.status = .closed }
            }
        }
    }

    /// Called after a request resolves; collapse if the pointer is away and
    /// nothing else pends.
    func collapseAgentIfIdle() {
        guard status == .expanded(.agent),
              !AppServices.shared.agents.hasPendingRequest,
              !pointerInside
        else { return }
        collapse()
    }

    /// Click on the closed (or hovered) notch opens the panel.
    func handleTap() {
        // Buttons inside HUD/pop content must not also trigger the root
        // fallback and expand the whole notch on mouse-up.
        guard status == .closed else { return }
        expand(lastTab)
    }

    // MARK: - HUD

    private(set) var hudValue: Double = 0
    private(set) var hudMuted = false
    private var hudDismissTask: Task<Void, Never>?

    func showHUD(_ kind: HUDKind, value: Double, muted: Bool = false) {
        // Never interrupt an open panel; the action still happened.
        if status.isExpanded { return }
        let settings = SettingsStore.shared
        let isVolume = kind == .volume
        let speed = isVolume ? settings.soundAnimSpeed : settings.displayAnimSpeed
        let duration = isVolume ? settings.soundHUDDuration : settings.displayHUDDuration

        mnotchLog.notice("showHUD \(String(describing: kind), privacy: .public) value=\(value)")
        hudValue = value
        hudMuted = muted
        hudDismissTask?.cancel()
        if status != .hud(kind) {
            withAnimation(Anim.hud(speed)) { status = .hud(kind) }
        }
        hudDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard !Task.isCancelled, let self else { return }
            if case .hud = self.status {
                withAnimation(Anim.close) { self.status = .closed }
            }
        }
    }

    // MARK: - Pops

    private var popDismissTask: Task<Void, Never>?

    func showPop(_ kind: PopKind) {
        // Priority: user hover/expanded > HUD > pop.
        guard !status.isExpanded else { return }
        if case .hud = status { return }

        let settings = SettingsStore.shared
        let duration: Double = switch kind {
        case .accessibility: 8
        case .charging, .lowBattery, .lowPower: settings.batteryDuration
        case .device: settings.connectivityDuration
        case .focus: settings.focusDuration
        case .event: settings.calendarPeekDuration
        case .agent: settings.agentDuration
        case .agentConfirm: 1.2   // driven by confirmAgentDecision, not showPop
        case .pomodoro: 4
        }

        let logKind = switch kind {
        case .accessibility: "accessibility"
        case .charging: "charging"
        case .lowBattery: "low-battery"
        case .lowPower: "low-power"
        case .device: "device"
        case .focus: "focus"
        case .event: "calendar-event"
        case .agent: "agent"
        case .agentConfirm: "agent-confirm"
        case .pomodoro: "pomodoro"
        }
        mnotchLog.debug("showPop kind=\(logKind, privacy: .public)")
        withAnimation(Anim.pop) { status = .pop(kind) }
        popDismissTask?.cancel()
        popDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard !Task.isCancelled, let self else { return }
            if case .pop = self.status {
                withAnimation(Anim.close) { self.status = .closed }
            }
        }
    }

    func dismissAccessibilityNotice() {
        guard status == .pop(.accessibility) else { return }
        popDismissTask?.cancel()
        withAnimation(Anim.close) { status = .closed }
    }

    // MARK: - Transitions

    func expand(_ tab: NotchTab) {
        let tab = resolvedTab(tab)
        lastTab = tab
        if tab == .agent, !AppServices.shared.agents.hasPendingRequest {
            agentContentHeight = Self.agentDashboardHeight
        }
        let wasExpanded = status.isExpanded
        withAnimation(Anim.open) { status = .expanded(tab) }
        if !wasExpanded, SettingsStore.shared.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment, performanceTime: .default
            )
        }
    }

    func collapse() {
        withAnimation(Anim.close) { status = .closed }
    }

    func selectTab(_ tab: NotchTab) {
        let tab = resolvedTab(tab)
        lastTab = tab
        if tab == .agent, !AppServices.shared.agents.hasPendingRequest {
            agentContentHeight = Self.agentDashboardHeight
        }
        withAnimation(Anim.open) { status = .expanded(tab) }
    }

    func isTabEnabled(_ tab: NotchTab) -> Bool {
        let settings = SettingsStore.shared
        return switch tab {
        case .media: settings.mediaEnabled
        case .shelf: settings.shelfEnabled
        case .calendar: settings.calendarEnabled
        case .pomodoro: settings.pomodoroEnabled
        case .agent: settings.agentEnabled
        }
    }

    private func resolvedTab(_ requested: NotchTab) -> NotchTab {
        guard !isTabEnabled(requested) else { return requested }
        return NotchTab.allCases.first(where: isTabEnabled) ?? .media
    }
}

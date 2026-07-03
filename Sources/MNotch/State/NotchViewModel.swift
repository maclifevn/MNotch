import SwiftUI

enum NotchTab: String, CaseIterable {
    case media
    case shelf
    case calendar
}

enum HUDKind: Equatable {
    case volume
    case brightness
    case keyboardBacklight
}

enum PopKind: Equatable {
    case charging(percentage: Int)
    case lowBattery(percentage: Int)
    case lowPower(on: Bool)
    case device(name: String, symbol: String, battery: Int?)
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

    /// Extra width added to each side of the closed notch while media plays.
    static let mediaWingWidth: CGFloat = 26

    /// Alcove's expanded panel is ~2.05:1.
    static let expandedSize = CGSize(width: 420, height: 205)
    static let hudExtraWidth: CGFloat = 160
    static let hudExtraHeight: CGFloat = 10
    static let popExtraWidth: CGFloat = 190
    static let popExtraHeight: CGFloat = 6

    /// Fixed panel (window) size — never animated, big enough for max expansion.
    static let panelSize = CGSize(width: 700, height: 300)

    /// Hover apron: interactive region extends this far past the visible shape.
    static let apron: CGFloat = 8

    /// Subtle growth while hovering the closed notch (Alcove-style feedback);
    /// expanding requires a click.
    static let hoverGrowth = CGSize(width: 18, height: 4)

    var closedSize: CGSize {
        let wings = mediaActive ? Self.mediaWingWidth * 2 : 0
        return CGSize(
            width: geometry.notchWidth + topRadius * 2 + wings,
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
        case .pop:
            return CGSize(
                width: closedSize.width + Self.popExtraWidth,
                height: closedSize.height + Self.popExtraHeight
            )
        case .expanded:
            return Self.expandedSize
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
                self.collapse()
            }
        }
    }

    /// Click on the closed (or hovered) notch opens the panel.
    func handleTap() {
        guard !status.isExpanded else { return }
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
        case .charging, .lowBattery, .lowPower: settings.batteryDuration
        case .device: settings.connectivityDuration
        }

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

    // MARK: - Transitions

    func expand(_ tab: NotchTab) {
        lastTab = tab
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
        lastTab = tab
        withAnimation(Anim.open) { status = .expanded(tab) }
    }
}

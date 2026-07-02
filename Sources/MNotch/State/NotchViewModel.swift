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
    case charging
    case lowBattery
    case device
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

    static let expandedSize = CGSize(width: 520, height: 190)
    static let hudExtraWidth: CGFloat = 40
    static let hudExtraHeight: CGFloat = 10
    static let popExtraWidth: CGFloat = 190
    static let popExtraHeight: CGFloat = 6

    /// Fixed panel (window) size — never animated, big enough for max expansion.
    static let panelSize = CGSize(width: 700, height: 300)

    /// Hover apron: interactive region extends this far past the visible shape.
    static let apron: CGFloat = 8

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
            return closedSize
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

    /// Interactive bounds in AppKit view coordinates (origin bottom-left),
    /// for `NotchHostingView.hitTest` and hover math. Slightly larger than the
    /// visible shape so tiny pointer overshoots don't collapse the panel.
    func interactiveRect(in bounds: CGRect) -> CGRect {
        let size = visualSize
        let width = size.width + Self.apron * 2
        let height = size.height + Self.apron
        return CGRect(
            x: (bounds.width - width) / 2,
            y: bounds.height - height,
            width: width,
            height: height
        )
    }

    // MARK: - Hover intent

    static let openDelay: Duration = .milliseconds(120)
    static let closeDelay: Duration = .milliseconds(350)

    private var pointerInside = false
    private var hoverTask: Task<Void, Never>?

    func setPointerInside(_ inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverTask?.cancel()

        if inside {
            guard !status.isExpanded else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: Self.openDelay)
                guard !Task.isCancelled, let self, self.pointerInside else { return }
                self.expand(self.lastTab)
            }
        } else {
            guard status.isExpanded else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: Self.closeDelay)
                guard !Task.isCancelled, let self, !self.pointerInside else { return }
                self.collapse()
            }
        }
    }

    // MARK: - Transitions

    func expand(_ tab: NotchTab) {
        lastTab = tab
        withAnimation(Anim.open) { status = .expanded(tab) }
    }

    func collapse() {
        withAnimation(Anim.close) { status = .closed }
    }

    func selectTab(_ tab: NotchTab) {
        lastTab = tab
        withAnimation(Anim.open) { status = .expanded(tab) }
    }
}

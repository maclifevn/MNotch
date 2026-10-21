import AppKit
import SwiftUI

/// Hosts the SwiftUI tree and implements mouse pass-through: anything outside
/// the current notch shape falls through to the menu bar / app beneath.
/// The window controller computes hover from the live interactive rect, rather
/// than SwiftUI tracking areas, so an animating shape never flickers at its
/// boundary.
final class NotchHostingView: NSHostingView<NotchRootView> {
    private let viewModel: NotchViewModel

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(rootView: NotchRootView(viewModel: viewModel))
        registerForDraggedTypes([.fileURL])
    }

    @MainActor @preconcurrency required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @MainActor @preconcurrency required init(rootView: NotchRootView) {
        fatalError("init(rootView:) is not supported")
    }

    /// Deliver controls their first click without making the overlay key or
    /// deactivating the user's current Finder/application window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The content-view hit-test chain supplies this point in the
        // superview's non-flipped coordinates. Convert it before comparing
        // with our top-left-origin interactive rect; otherwise the real notch
        // is rejected and the click falls through to the menu bar below.
        let local = convert(point, from: superview)
        guard viewModel.interactiveRect(in: bounds, flipped: isFlipped).contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// Region-aware window pass-through support. `hitTest(nil)` only declines
    /// a view inside this window; it does not make the NSWindow transparent to
    /// the application underneath. NotchPanel uses this result to drive the
    /// authoritative `ignoresMouseEvents` property.
    func containsInteractivePoint(_ screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let local = convert(windowPoint, from: nil)
        return viewModel.interactiveRect(in: bounds, flipped: isFlipped).contains(local)
    }

    func setPresentationSuppressed(_ suppressed: Bool) {
        viewModel.isPresentationSuppressed = suppressed
    }

    func setPointerInsideFromWindow(_ inside: Bool) {
        viewModel.setPointerInside(inside)
    }

    // Hover and window pass-through intentionally share the same rectangle in
    // NotchPanel. A second SwiftUI onHover source would disagree over the 8pt
    // apron and rapidly toggle the spring while the pointer sits at the edge.

    /// Fallback for SwiftUI gestures being unreliable in a never-key panel:
    /// a click on the closed notch expands it. No-op when already expanded
    /// (handleTap guards), so a SwiftUI tap firing too costs nothing.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let local = convert(event.locationInWindow, from: nil)
        if viewModel.interactiveRect(in: bounds, flipped: isFlipped).contains(local) {
            viewModel.handleTap()
        }
    }

    // MARK: - Two-finger swipe gestures

    private var accumX: CGFloat = 0
    private var accumY: CGFloat = 0
    private var gestureConsumed = false

    override func scrollWheel(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard viewModel.interactiveRect(in: bounds, flipped: isFlipped).contains(local),
              event.momentumPhase == []
        else {
            super.scrollWheel(with: event)
            return
        }

        switch event.phase {
        case .began:
            accumX = 0
            accumY = 0
            gestureConsumed = false
        case .changed:
            accumX += event.scrollingDeltaX
            accumY += event.scrollingDeltaY
            handleSwipeIfReady()
        case .ended, .cancelled:
            accumX = 0
            accumY = 0
            gestureConsumed = false
        default:
            break
        }
    }

    private func handleSwipeIfReady() {
        guard !gestureConsumed else { return }
        let settings = SettingsStore.shared

        // scrollingDeltaY > 0 = fingers swiping down (with system natural
        // scrolling pre-applied); the Natural toggle flips it.
        let downward = settings.gestureNatural ? -accumY : accumY

        if abs(accumX) > 35, abs(accumX) > abs(accumY) * 1.5 {
            gestureConsumed = true
            guard !viewModel.status.isExpanded else { return }
            let media = AppServices.shared.media
            if viewModel.mediaActive, settings.gestureSkipMedia {
                media.send(accumX < 0 ? .nextTrack : .previousTrack)
            } else if settings.gestureCycleActivity {
                viewModel.cycleActivity()
            }
            return
        }

        if downward > 25 {
            gestureConsumed = true
            if !viewModel.status.isExpanded, settings.gestureToggleOpen {
                viewModel.expand(viewModel.lastTab)
            }
        } else if downward < -25 {
            gestureConsumed = true
            if viewModel.status.isExpanded {
                if settings.gestureToggleOpen {
                    viewModel.collapse()
                }
            } else if settings.gestureDismissActivity {
                viewModel.dismissActivity()
            }
        }
    }

    // MARK: - Shelf drag-and-drop (auto-expands the shelf on hover)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ShelfDropPolicy.accepts(
            featureEnabled: SettingsStore.shared.shelfEnabled && !ShelfStore.shared.isPreparingForUpdate,
            outgoingShelfDrag: ShelfOutgoingDragState.isActive
        ) else { return [] }
        viewModel.expand(.shelf)
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard ShelfDropPolicy.accepts(
            featureEnabled: SettingsStore.shared.shelfEnabled && !ShelfStore.shared.isPreparingForUpdate,
            outgoingShelfDrag: ShelfOutgoingDragState.isActive
        ) else { return false }
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        ShelfStore.shared.add(urls)
        return true
    }
}

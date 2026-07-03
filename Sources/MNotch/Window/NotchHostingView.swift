import AppKit
import SwiftUI

/// Hosts the SwiftUI tree and implements mouse pass-through: anything outside
/// the current notch shape falls through to the menu bar / app beneath.
/// Hover is computed here from raw mouse events against the view model's
/// interactive rect — not SwiftUI `onHover` — so an animating shape never
/// flickers hover state.
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

    /// The panel never becomes key, so without this the first click is
    /// swallowed as window activation and gestures never fire.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard viewModel.interactiveRect(in: bounds, flipped: isFlipped).contains(local) else { return nil }
        return super.hitTest(point)
    }

    // Hover detection lives in SwiftUI (`.onHover` on the notch body): its
    // tracking areas follow the animated layout automatically, which raw
    // NSTrackingArea + mouseMoved did not do reliably in a non-activating
    // panel. This view only handles click pass-through (hitTest) and drops.

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
        guard SettingsStore.shared.shelfEnabled else { return [] }
        viewModel.expand(.shelf)
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard SettingsStore.shared.shelfEnabled else { return false }
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        ShelfStore.shared.add(urls)
        return true
    }
}

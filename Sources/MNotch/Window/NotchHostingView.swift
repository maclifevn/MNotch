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

import AppKit

/// Always-resident, non-activating, transparent panel pinned over the notch.
/// The window frame is fixed at `NotchViewModel.panelSize` and NEVER animates —
/// all motion happens inside the SwiftUI content.
final class NotchPanel: NSPanel {
    /// Tunable: escalate toward `.screenSaver` if fullscreen chrome overdraws us.
    static let notchLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    init(screen: NSScreen, viewModel: NotchViewModel) {
        let size = NotchViewModel.panelSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // Window shadow would repaint on every content change; any glow is
        // drawn inside SwiftUI instead.
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // Allows the panel to stay visible when elevated over the lock screen.
        canBecomeVisibleWithoutLogin = true
        level = Self.notchLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NotchHostingView(viewModel: viewModel)
        setFrame(frame, display: true)
    }

    // SwiftUI controls in a non-key panel swallow the first click (it's spent
    // becoming focused), so tab/button taps registered only "sometimes". Allow
    // the panel to become key; `.nonactivatingPanel` keeps this from activating
    // the app or stealing the menu bar.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Become key on the mouse-DOWN, before the event is routed, so the very
    /// first tap on a control fires it instead of just focusing the panel.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }
}

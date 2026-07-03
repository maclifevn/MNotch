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
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // Allows the panel to stay visible when elevated over the lock screen.
        canBecomeVisibleWithoutLogin = true
        level = Self.notchLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NotchHostingView(viewModel: viewModel)
        setFrame(frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

import AppKit

/// Always-resident, non-activating, transparent panel pinned over the notch.
/// The window frame is fixed at `NotchViewModel.panelSize` and NEVER animates —
/// all motion happens inside the SwiftUI content.
final class NotchPanel: NSPanel {
    /// Tunable: escalate toward `.screenSaver` if fullscreen chrome overdraws us.
    static let notchLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    private var interactionSuppressed = false
    private var outgoingDragActive = false

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
        // A 700×448 transparent window otherwise intercepts clicks well beyond
        // the visible notch. The controller enables events only while the
        // pointer is inside the current interactive shape.
        ignoresMouseEvents = true
        // Allows the panel to stay visible when elevated over the lock screen.
        canBecomeVisibleWithoutLogin = true
        level = Self.notchLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NotchHostingView(viewModel: viewModel)
        setFrame(frame, display: true)
    }

    // This overlay must never become key. A non-activating panel that calls
    // makeKey() still takes key-window status away from Finder/System Settings,
    // leaving their chrome inactive and making the next click look swallowed.
    // NotchHostingView.acceptsFirstMouse handles first-click delivery instead.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setInteractionSuppressed(_ suppressed: Bool) {
        interactionSuppressed = suppressed
        if suppressed {
            ignoresMouseEvents = true
            (contentView as? NotchHostingView)?.setPointerInsideFromWindow(false)
        }
    }

    func updatePointerInteraction(
        at screenPoint: NSPoint,
        mouseButtonPressed: Bool
    ) {
        guard !interactionSuppressed,
              !outgoingDragActive,
              let hosting = contentView as? NotchHostingView
        else {
            ignoresMouseEvents = true
            return
        }

        // Once a slider/file drag starts in the notch, retain the event stream
        // until mouse-up even if the pointer briefly leaves the visual shape.
        if mouseButtonPressed, !ignoresMouseEvents { return }

        let inside = hosting.containsInteractivePoint(screenPoint)
        hosting.setPointerInsideFromWindow(inside)
        if ignoresMouseEvents == inside {
            ignoresMouseEvents = !inside
        }
    }

    /// A native drag session keeps its source alive independently of normal
    /// window mouse routing. Passing this oversized transparent panel through
    /// is therefore safe and exposes the real Finder/browser destination below.
    func setOutgoingDragActive(_ active: Bool) {
        guard outgoingDragActive != active else { return }
        outgoingDragActive = active
        if active {
            ignoresMouseEvents = true
        } else {
            updatePointerInteraction(
                at: NSEvent.mouseLocation,
                mouseButtonPressed: NSEvent.pressedMouseButtons != 0
            )
        }
    }
}

import AppKit

/// Always-resident, non-activating, transparent panel pinned over the notch.
/// The window frame is fixed at `NotchViewModel.panelSize` and NEVER animates —
/// all motion happens inside the SwiftUI content.
final class NotchPanel: NSPanel {
    /// Tunable: escalate toward `.screenSaver` if fullscreen chrome overdraws us.
    static let notchLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    private let viewModel: NotchViewModel
    private var occlusion: NotchOcclusion = .visible
    private var occlusionHidden = false
    private var interactionSuppressed = false
    private var outgoingDragActive = false
    private var outgoingDragDeadline: Date?
    private var outsideDragStartedAt: Date?
    private static let outsideDragGrace: TimeInterval = 2
    private static let outgoingDragFailsafe: TimeInterval = 30

    init(screen: NSScreen, viewModel: NotchViewModel) {
        self.viewModel = viewModel
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
        viewModel.onStatusChanged = { [weak self] in
            guard let self, self.occlusion == .fullscreen else { return }
            // Hide at dismissal before the closed shape can flash onscreen.
            // Width/content animation remains owned by the SwiftUI HUD.
            self.refreshOcclusion(animated: false)
        }
    }

    // This overlay must never become key. A non-activating panel that calls
    // makeKey() still takes key-window status away from Finder/System Settings,
    // leaving their chrome inactive and making the next click look swallowed.
    // NotchHostingView.acceptsFirstMouse handles first-click delivery instead.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setOcclusion(_ occlusion: NotchOcclusion, animated: Bool = true) {
        guard occlusion != self.occlusion else { return }
        self.occlusion = occlusion
        refreshOcclusion(animated: animated)
    }

    private func refreshOcclusion(animated: Bool) {
        let hidden = occlusion.hidesPanel(showingHUD: viewModel.status.isHUD)
        // A fullscreen HUD is passive: hovering/clicking it must not reveal
        // the normal notch, while its visible contents remain free to render.
        setInteractionSuppressed(occlusion != .visible, presentationSuppressed: hidden)
        guard hidden != occlusionHidden else { return }
        occlusionHidden = hidden
        mnotchLog.debug("notch visibility occlusion=\(String(describing: self.occlusion), privacy: .public) hud=\(self.viewModel.status.isHUD) hidden=\(hidden)")
        if animated && isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Anim.reduceMotion ? 0.1 : 0.25
                animator().alphaValue = hidden ? 0 : 1
            }
        } else {
            alphaValue = hidden ? 0 : 1
        }
    }

    func setInteractionSuppressed(_ suppressed: Bool, presentationSuppressed: Bool? = nil) {
        interactionSuppressed = suppressed
        (contentView as? NotchHostingView)?.setPresentationSuppressed(presentationSuppressed ?? suppressed)
        if suppressed {
            ignoresMouseEvents = true
            outsideDragStartedAt = nil
            (contentView as? NotchHostingView)?.setPointerInsideFromWindow(false)
        }
    }

    func updatePointerInteraction(
        at screenPoint: NSPoint,
        mouseButtonPressed: Bool
    ) {
        // AppKit normally sends draggingSession(...endedAt:...), but a source
        // app/window disappearing mid-drag can skip it. Never leave this
        // always-on-top panel permanently mouse-transparent.
        if outgoingDragActive,
           let deadline = outgoingDragDeadline,
           Date() >= deadline {
            outgoingDragActive = false
            outgoingDragDeadline = nil
        }

        guard !interactionSuppressed,
              !outgoingDragActive,
              let hosting = contentView as? NotchHostingView
        else {
            ignoresMouseEvents = true
            return
        }

        let inside = hosting.containsInteractivePoint(screenPoint)

        // Once a slider drag starts in the notch, retain the event stream while
        // the pointer briefly leaves the shape. If a mouse utility/driver loses
        // mouse-up and pressedMouseButtons remains stuck, release after a short
        // outside-only grace period so the notch can recover by itself.
        if mouseButtonPressed, !ignoresMouseEvents {
            if inside {
                outsideDragStartedAt = nil
                return
            }
            let began = outsideDragStartedAt ?? Date()
            outsideDragStartedAt = began
            if Date().timeIntervalSince(began) < Self.outsideDragGrace {
                return
            }
        } else {
            outsideDragStartedAt = nil
        }

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
            outgoingDragDeadline = Date().addingTimeInterval(Self.outgoingDragFailsafe)
            ignoresMouseEvents = true
        } else {
            outgoingDragDeadline = nil
            updatePointerInteraction(
                at: NSEvent.mouseLocation,
                mouseButtonPressed: NSEvent.pressedMouseButtons != 0
            )
        }
    }
}

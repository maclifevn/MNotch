import AppKit

/// Owns one NotchPanel per eligible screen and rebuilds on display changes
/// (lid open/close, hot-plug). Panels are long-lived otherwise.
@MainActor
final class NotchWindowController {
    private var panels: [NotchPanel] = []
    private var viewModels: [NotchViewModel] = []
    private var rebuildTask: Task<Void, Never>?
    private var wakeRecoveryTask: Task<Void, Never>?
    private var pointerTimer: Timer?
    /// SkyLight removes windows from their desktop spaces. Only a full rebuild
    /// can safely restore them, and only after we actually attempted elevation.
    private var needsDesktopRebuild = false

    init() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            // Installed on the main run loop below, so this isolation assertion
            // avoids allocating a Swift Task on every pointer sample.
            MainActor.assumeIsolated {
                self?.refreshPointerInteractions()
            }
        }
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    func stop() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        rebuildTask?.cancel()
        rebuildTask = nil
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        panels.forEach { $0.close() }
        panels.removeAll()
        viewModels.removeAll()
    }

    var debugPanels: [NotchPanel] { panels }
    var debugViewModels: [NotchViewModel] { viewModels }

    func showAll() {
        rebuild()
    }

    func repositionAll() {
        scheduleRebuild()
    }

    /// Display topology, WindowServer spaces and CoreAudio recover at slightly
    /// different times after clamshell wake. Rebuild once immediately through
    /// the normal screen-parameter notification, then once after the wake burst
    /// settles so no stale/hidden panel survives from the sleeping display.
    func recoverAfterDisplayWake() {
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            self.wakeRecoveryTask = nil
            self.rebuild()
        }
    }

    private func rebuild() {
        rebuildTask?.cancel()
        rebuildTask = nil
        for panel in panels {
            panel.close()
        }
        panels = []
        viewModels = []

        let settings = SettingsStore.shared
        let elevateForLock = LockPresentationPolicy.shouldElevateNotch(
            isLocked: AppServices.shared.lockScreen.isLocked,
            featureEnabled: settings.lockEnabled && PrivateAPICompatibility.permits(.lockScreen)
        )
        let occlusion = AppServices.shared.occlusion.state

        // When no display has a real notch (Mac mini/Studio, Intel Macs, or a
        // MacBook running lid-closed on an external), fall back to a simulated
        // notch automatically — otherwise the app would draw nothing at all.
        let anyRealNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        let simulate = SimulatedNotchPolicy.isEnabled(
            force: settings.forceSimulatedNotch,
            hasPhysicalNotch: anyRealNotch
        )

        for screen in NSScreen.screens
        where (screen.safeAreaInsets.top > 0 || simulate)
            && Self.isTargeted(screen, target: settings.displayTarget) {
            let viewModel = NotchViewModel(geometry: .forScreen(screen))
            let panel = NotchPanel(screen: screen, viewModel: viewModel)
            panel.sharingType = settings.hideFromScreenCapture ? .none : .readOnly
            // Rebuilds can happen mid-lock (display sleep/wake fires screen
            // parameter changes) or while hidden for a fullscreen app; new
            // panels must adopt the CURRENT state, not the default one.
            if elevateForLock {
                panel.level = NSWindow.Level(rawValue: Int(Int32.max) - 2)
            }
            panel.setOcclusion(occlusion, animated: false)
            if elevateForLock {
                // The window must already be ordered before SkyLight moves it;
                // ordering it afterward can pull it back to the desktop space.
                panel.orderFrontRegardless()
                needsDesktopRebuild = true
                if !SkyLightOperator.shared.addToLockSpace(panel) {
                    panel.setInteractionSuppressed(true)
                    panel.orderOut(nil)
                }
            } else {
                panel.orderFrontRegardless()
            }
            panels.append(panel)
            viewModels.append(viewModel)
        }
        refreshPointerInteractions()

        SettingsStore.shared.onDisplayConfigChanged = { [weak self] in
            self?.scheduleRebuild()
        }
        AppServices.shared.showHUD = { [weak self] kind, value, muted in
            self?.viewModels.forEach { $0.showHUD(kind, value: value, muted: muted) }
        }
        AppServices.shared.showPop = { [weak self] kind in
            self?.viewModels.forEach { $0.showPop(kind) }
        }
        // Agent permission request → open the Agent tab on every panel; the
        // built-in (or first) notch is where the user acts.
        AppServices.shared.expandAgent = { [weak self] in
            self?.viewModels.forEach { $0.openAgentRequest() }
        }
        AppServices.shared.collapseIfIdle = { [weak self] in
            self?.viewModels.forEach { $0.collapseAgentIfIdle() }
        }
        AppServices.shared.dismissAccessibilityNotice = { [weak self] in
            self?.viewModels.forEach { $0.dismissAccessibilityNotice() }
        }
        AppServices.shared.displayDidWake = { [weak self] in
            self?.recoverAfterDisplayWake()
        }
        // While locked, move the notch panels into the SkyLight lock-screen
        // space so HUDs/pops stay visible over the shield (Alcove behavior).
        // SLSSpaceAddWindowsAndRemoveFromSpaces REMOVES windows from their
        // normal spaces permanently, so unlocking rebuilds the panels from
        // scratch — a level reset alone would leave them parked in the
        // level-400 lock space forever.
        AppServices.shared.lockScreen.onLockPresentationChanged = { [weak self] elevate in
            guard let self else { return }
            if elevate {
                self.needsDesktopRebuild = true
                self.panels.forEach {
                    $0.level = NSWindow.Level(rawValue: Int(Int32.max) - 2)
                    if !SkyLightOperator.shared.addToLockSpace($0) {
                        $0.setInteractionSuppressed(true)
                        $0.orderOut(nil)
                    }
                }
            } else if self.needsDesktopRebuild {
                self.needsDesktopRebuild = false
                self.rebuild()
            }
        }
        AppServices.shared.occlusion.onChange = { [weak self] occlusion in
            guard let self else { return }
            for panel in self.panels {
                panel.setOcclusion(occlusion)
            }
            if occlusion == .visible { self.refreshPointerInteractions() }
        }
    }

    /// Display notifications and tuning sliders can arrive in bursts. Reusing
    /// one short debounce prevents repeatedly destroying/recreating every panel
    /// on the main thread while the user drags a slider or opens a laptop lid.
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    private func refreshPointerInteractions() {
        let location = NSEvent.mouseLocation
        let pressed = NSEvent.pressedMouseButtons != 0
        for panel in panels where panel.isVisible {
            panel.updatePointerInteraction(
                at: location,
                mouseButtonPressed: pressed
            )
        }
    }

    /// "all" | "main" | "builtIn" | CGDirectDisplayID as string
    private static func isTargeted(_ screen: NSScreen, target: String) -> Bool {
        switch target {
        case "all":
            return true
        case "main":
            // Primary display only — NSScreen.main follows key-window focus
            // and would nondeterministically match a second screen.
            return screen == NSScreen.screens.first
        case "builtIn":
            return screen.safeAreaInsets.top > 0 || CGDisplayIsBuiltin(screen.displayID) != 0
        default:
            return String(screen.displayID) == target
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }
}

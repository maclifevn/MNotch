import AppKit

/// Owns one NotchPanel per eligible screen and rebuilds on display changes
/// (lid open/close, hot-plug). Panels are long-lived otherwise.
@MainActor
final class NotchWindowController {
    private var panels: [NotchPanel] = []
    private var viewModels: [NotchViewModel] = []

    var debugPanels: [NotchPanel] { panels }
    var debugViewModels: [NotchViewModel] { viewModels }

    func showAll() {
        rebuild()
    }

    func repositionAll() {
        rebuild()
    }

    private func rebuild() {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels = []
        viewModels = []

        let settings = SettingsStore.shared
        for screen in NSScreen.screens
        where (screen.safeAreaInsets.top > 0 || settings.forceSimulatedNotch)
            && Self.isTargeted(screen, target: settings.displayTarget) {
            let viewModel = NotchViewModel(geometry: .forScreen(screen))
            let panel = NotchPanel(screen: screen, viewModel: viewModel)
            panel.sharingType = settings.hideFromScreenCapture ? .none : .readOnly
            panel.orderFrontRegardless()
            panels.append(panel)
            viewModels.append(viewModel)
        }

        SettingsStore.shared.onDisplayConfigChanged = { [weak self] in
            self?.rebuild()
        }
        AppServices.shared.showHUD = { [weak self] kind, value, muted in
            self?.viewModels.forEach { $0.showHUD(kind, value: value, muted: muted) }
        }
        AppServices.shared.showPop = { [weak self] kind in
            self?.viewModels.forEach { $0.showPop(kind) }
        }
        // While locked, move the notch panels into the SkyLight lock-screen
        // space so HUDs/pops stay visible over the shield (Alcove behavior).
        AppServices.shared.lockScreen.onLockStateChanged = { [weak self] locked in
            guard let self else { return }
            if locked {
                self.panels.forEach {
                    $0.level = NSWindow.Level(rawValue: Int(Int32.max) - 2)
                    SkyLightOperator.shared.addToLockSpace($0)
                }
            } else {
                self.panels.forEach { $0.level = NotchPanel.notchLevel }
            }
        }
        AppServices.shared.occlusion.onHideChanged = { [weak self] hide in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                for panel in self.panels {
                    panel.animator().alphaValue = hide ? 0 : 1
                }
            }
            for panel in self.panels {
                panel.ignoresMouseEvents = hide
            }
        }
    }

    /// "all" | "main" | "builtIn" | CGDirectDisplayID as string
    private static func isTargeted(_ screen: NSScreen, target: String) -> Bool {
        switch target {
        case "all":
            return true
        case "main":
            return screen == NSScreen.main || screen == NSScreen.screens.first
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

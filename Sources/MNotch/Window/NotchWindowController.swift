import AppKit

/// Owns one NotchPanel per eligible screen and rebuilds on display changes
/// (lid open/close, hot-plug). Panels are long-lived otherwise.
@MainActor
final class NotchWindowController {
    private var panels: [NotchPanel] = []
    private var viewModels: [NotchViewModel] = []

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

        let fakeNotch = SettingsStore.shared.fakeNotchOnExternal
        for screen in NSScreen.screens
        where screen.safeAreaInsets.top > 0 || fakeNotch {
            let viewModel = NotchViewModel(geometry: .forScreen(screen))
            let panel = NotchPanel(screen: screen, viewModel: viewModel)
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
    }
}

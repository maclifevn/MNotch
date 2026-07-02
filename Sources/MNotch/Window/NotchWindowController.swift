import AppKit

/// Owns one NotchPanel per eligible screen and rebuilds on display changes
/// (lid open/close, hot-plug). Panels are long-lived otherwise.
@MainActor
final class NotchWindowController {
    private var panels: [NotchPanel] = []

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
        // Built-in (physical notch) screens only for now; fake-notch external
        // display support arrives with the settings toggle.
        panels = NSScreen.screens
            .filter { $0.safeAreaInsets.top > 0 }
            .map { screen in
                let viewModel = NotchViewModel(geometry: .forScreen(screen))
                let panel = NotchPanel(screen: screen, viewModel: viewModel)
                panel.orderFrontRegardless()
                return panel
            }
    }
}

import AppKit

/// Decides when the notch UI should get out of the way: fullscreen apps,
/// Mission Control, games, or (for media chrome) the media source app being
/// frontmost. Polls lightly (1s) and reacts to app activation immediately;
/// the CGWindowList scan only runs while a hide toggle is actually on.
@MainActor
@Observable
final class OcclusionWatcher {
    /// Panels fade out while true.
    private(set) var shouldHide = false
    private(set) var frontmostBundleID: String?

    @ObservationIgnored var onHideChanged: ((Bool) -> Void)?

    @ObservationIgnored private var timer: Timer?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        evaluate()
    }

    private func evaluate() {
        let settings = SettingsStore.shared
        let frontmost = NSWorkspace.shared.frontmostApplication
        frontmostBundleID = frontmost?.bundleIdentifier

        var hide = false

        if settings.hideWhileGaming, let app = frontmost, Self.isGame(app) {
            hide = true
        }

        if !hide, settings.hideInFullscreen || settings.hideInMissionControl {
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []

            if settings.hideInFullscreen,
               let app = frontmost,
               app.bundleIdentifier != Bundle.main.bundleIdentifier,
               Self.hasFullscreenWindow(in: windows, pid: app.processIdentifier) {
                hide = true
            }
            if !hide, settings.hideInMissionControl, Self.missionControlActive(in: windows) {
                hide = true
            }
        }

        if hide != shouldHide {
            shouldHide = hide
            onHideChanged?(hide)
        }
    }

    // MARK: - Heuristics

    private nonisolated static func isGame(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL,
              let category = Bundle(url: url)?
                .infoDictionary?["LSApplicationCategoryType"] as? String
        else { return false }
        return category.contains("games")
    }

    /// A layer-0 window of the frontmost app covering an entire screen.
    private static func hasFullscreenWindow(in windows: [[String: Any]], pid: pid_t) -> Bool {
        let screenSizes = NSScreen.screens.map(\.frame.size)
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = boundsDict["Width"], let height = boundsDict["Height"]
            else { continue }
            if screenSizes.contains(where: { abs($0.width - width) < 2 && abs($0.height - height) < 2 }) {
                return true
            }
        }
        return false
    }

    private static func missionControlActive(in windows: [[String: Any]]) -> Bool {
        windows.contains { window in
            (window[kCGWindowOwnerName as String] as? String) == "Dock"
                && (window[kCGWindowName as String] as? String) == "Mission Control"
        }
    }
}

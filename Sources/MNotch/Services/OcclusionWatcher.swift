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
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var evaluationTask: Task<Void, Never>?
    @ObservationIgnored private var evaluationRequested = false

    func start() {
        guard timer == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
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

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        evaluationTask?.cancel()
        evaluationTask = nil
        evaluationRequested = false
        frontmostBundleID = nil
        if shouldHide {
            shouldHide = false
            onHideChanged?(false)
        }
    }

    private func evaluate() {
        guard evaluationTask == nil else {
            evaluationRequested = true
            return
        }

        let settings = SettingsStore.shared
        let frontmost = NSWorkspace.shared.frontmostApplication
        frontmostBundleID = frontmost?.bundleIdentifier

        var hide = false

        if settings.hideWhileGaming, let app = frontmost, Self.isGame(app) {
            hide = true
        }

        guard !hide, settings.hideInFullscreen || settings.hideInMissionControl else {
            apply(hide)
            return
        }

        let hideFullscreen = settings.hideInFullscreen
        let hideMissionControl = settings.hideInMissionControl
        let frontmostPID = frontmost?.processIdentifier
        let frontmostIsMNotch = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
        let screenSizes = NSScreen.screens.map(\.frame.size)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        evaluationTask = Task { [weak self] in
            let shouldHide = await Task.detached(priority: .utility) {
                let windows = CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements],
                    kCGNullWindowID
                ) as? [[String: Any]] ?? []

                if hideFullscreen,
                   let frontmostPID,
                   !frontmostIsMNotch,
                   Self.hasFullscreenWindow(
                       in: windows,
                       pid: frontmostPID,
                       screenSizes: screenSizes,
                       ownPID: ownPID
                   ) {
                    return true
                }
                return hideMissionControl && Self.missionControlActive(in: windows)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.evaluationTask = nil
            self.apply(shouldHide)
            if self.evaluationRequested {
                self.evaluationRequested = false
                self.evaluate()
            }
        }
    }

    private func apply(_ hide: Bool) {
        guard hide != shouldHide else { return }
        shouldHide = hide
        onHideChanged?(hide)
    }

    // MARK: - Heuristics

    private nonisolated static func isGame(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL,
              let category = Bundle(url: url)?
                .infoDictionary?["LSApplicationCategoryType"] as? String
        else { return false }
        return category.contains("games")
    }

    /// Fullscreen = a layer-0 window of the frontmost app covering a screen
    /// (allowing a menu-bar-sized shortfall — QuickTime presentation is
    /// screenHeight − 33), OR any app's frontmost layer-0 window covering a
    /// screen edge-to-edge (survives small system dialogs stealing frontmost;
    /// the exact-height requirement avoids matching merely-maximized windows).
    private nonisolated static func hasFullscreenWindow(
        in windows: [[String: Any]],
        pid: pid_t,
        screenSizes: [CGSize],
        ownPID: Int32
    ) -> Bool {
        var seenTopmostLayerZero = false
        for window in windows { // CGWindowList is ordered front-to-back
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != pid_t(ownPID),
                  let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = boundsDict["Width"], let height = boundsDict["Height"]
            else { continue }

            if ownerPID == pid,
               screenSizes.contains(where: {
                   abs($0.width - width) < 2 && height >= $0.height - 40
               }) {
                return true
            }

            if !seenTopmostLayerZero {
                seenTopmostLayerZero = true
                if screenSizes.contains(where: {
                    abs($0.width - width) < 2 && height >= $0.height - 1
                }) {
                    return true
                }
            }
        }
        return false
    }

    private nonisolated static func missionControlActive(in windows: [[String: Any]]) -> Bool {
        // kCGWindowName is only populated with Screen Recording permission,
        // so the name match alone would never fire. Fallback heuristic: during
        // Mission Control the Dock process owns a burst of thumbnail windows
        // (one per app window + per space); normal operation has only a few.
        var dockWindows = 0
        for window in windows where (window[kCGWindowOwnerName as String] as? String) == "Dock" {
            if (window[kCGWindowName as String] as? String) == "Mission Control" {
                return true
            }
            dockWindows += 1
        }
        return dockWindows > 8
    }
}

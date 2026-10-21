import AppKit

enum NotchOcclusion: Equatable, Sendable {
    case visible, fullscreen, missionControl, gaming

    func hidesPanel(showingHUD: Bool) -> Bool {
        switch self {
        case .visible: false
        case .fullscreen: !showingHUD
        case .missionControl, .gaming: true
        }
    }
}

/// Decides when the notch UI should get out of the way: fullscreen apps,
/// Mission Control, games, or (for media chrome) the media source app being
/// frontmost. Polls lightly (1s) and reacts to app activation immediately;
/// the CGWindowList scan only runs while a hide toggle is actually on.
@MainActor
@Observable
final class OcclusionWatcher {
    private(set) var state: NotchOcclusion = .visible
    private(set) var frontmostBundleID: String?

    @ObservationIgnored var onChange: ((NotchOcclusion) -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var evaluationTask: Task<Void, Never>?
    @ObservationIgnored private var evaluationRequested = false
    @ObservationIgnored private var frontmostPID: pid_t?
    @ObservationIgnored private var frontmostIsGame = false

    func start() {
        guard timer == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            Task { @MainActor in
                self?.updateFrontmost(app)
                self?.evaluate()
            }
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateFrontmost(NSWorkspace.shared.frontmostApplication)
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
        evaluationRequested = false
        frontmostBundleID = nil
        frontmostPID = nil
        frontmostIsGame = false
        apply(.visible)
    }

    private func evaluate() {
        guard timer != nil else { return }
        guard evaluationTask == nil else {
            evaluationRequested = true
            return
        }

        let settings = SettingsStore.shared

        if settings.hideWhileGaming, frontmostIsGame {
            apply(.gaming)
            return
        }

        guard settings.hideInFullscreen || settings.hideInMissionControl else {
            apply(.visible)
            return
        }

        let hideFullscreen = settings.hideInFullscreen
        let hideMissionControl = settings.hideInMissionControl
        let frontmostPID = self.frontmostPID
        let frontmostIsMNotch = frontmostBundleID == Bundle.main.bundleIdentifier
        let screenSizes = NSScreen.screens.map(\.frame.size)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        evaluationTask = Task { [weak self] in
            let state = await Task.detached(priority: .utility) { () -> NotchOcclusion in
                let windows = CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements],
                    kCGNullWindowID
                ) as? [[String: Any]] ?? []

                // Mission Control suppresses every surface, including a HUD
                // left over from the fullscreen space beneath its thumbnails.
                if hideMissionControl && Self.missionControlActive(in: windows) {
                    return .missionControl
                }
                if hideFullscreen,
                   let frontmostPID,
                   !frontmostIsMNotch,
                   Self.hasFullscreenWindow(
                       in: windows,
                       pid: frontmostPID,
                       screenSizes: screenSizes,
                       ownPID: ownPID
                   ) {
                    return .fullscreen
                }
                return .visible
            }.value

            guard let self else { return }
            self.evaluationTask = nil
            guard !Task.isCancelled else {
                if self.timer != nil { self.evaluate() }
                return
            }
            guard self.timer != nil else { return }
            self.apply(state)
            if self.evaluationRequested {
                self.evaluationRequested = false
                self.evaluate()
            }
        }
    }

    /// `NSRunningApplication` lazily fetches properties through LaunchServices
    /// XPC. Cache that snapshot only when AppKit reports an activation instead
    /// of paying for synchronous XPC on every one-second fullscreen poll.
    private func updateFrontmost(_ app: NSRunningApplication?) {
        frontmostBundleID = app?.bundleIdentifier
        frontmostPID = app?.processIdentifier
        frontmostIsGame = app.map(Self.isGame) ?? false
    }

    private func apply(_ state: NotchOcclusion) {
        guard state != self.state else { return }
        self.state = state
        onChange?(state)
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

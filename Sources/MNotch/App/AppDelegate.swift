import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private let statusItem = StatusItemController()
    private var permissionNoticeTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mnotchLog.notice("MNotch launched")
        AppServices.shared.startAll()
        notchController = NotchWindowController()
        notchController?.showAll()
#if DEBUG
        if let notchController {
            DebugProbe.install(controller: notchController)
        }
#endif
        statusItem.install()

        let returningUser = SettingsStore.shared.hasSeenWelcome
        // First launch: greet the user and walk them through the one permission
        // (Accessibility) that needs a manual grant.
        if !returningUser {
            WelcomeWindowController.shared.show()
        } else if AppServices.shared.accessibility.isRequiredForEnabledFeatures {
            // Returning users get one calm, actionable notch reminder per
            // launch. The menu-bar badge and Settings status remain persistent.
            permissionNoticeTask = Task {
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled,
                      AppServices.shared.accessibility.isRequiredForEnabledFeatures
                else { return }
                AppServices.shared.showPop?(.accessibility)
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screensChanged() {
        notchController?.repositionAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionNoticeTask?.cancel()
        AppServices.shared.stopAll()
    }
}

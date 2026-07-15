import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private let statusItem = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        mnotchLog.notice("MNotch launched")
        AppServices.shared.startAll()
        notchController = NotchWindowController()
        notchController?.showAll()
        if let notchController {
            DebugProbe.install(controller: notchController)
        }
        statusItem.install()

        // First launch: greet the user and walk them through the one permission
        // (Accessibility) that needs a manual grant.
        if !SettingsStore.shared.hasSeenWelcome {
            WelcomeWindowController.shared.show()
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
        AppServices.shared.stopAll()
    }
}

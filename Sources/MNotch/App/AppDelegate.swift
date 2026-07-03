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
        AppServices.shared.media.stop()
    }
}

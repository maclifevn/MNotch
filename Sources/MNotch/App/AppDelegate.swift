import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private let statusItem = StatusItemController()
    private let updates = AppUpdateController.shared
    private var permissionNoticeTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mnotchLog.notice("MNotch launched")
        installMainMenu()
        AppServices.shared.startAll()
        notchController = NotchWindowController()
        notchController?.showAll()
#if DEBUG
        if let notchController {
            DebugProbe.install(controller: notchController)
        }
#endif
        statusItem.install()
        // Start only after the app's services and user-facing entry points are
        // ready. Release builds then follow Sparkle's daily schedule.
        updates.start()

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

    /// An accessory (LSUIElement) app never displays a menu bar, but AppKit
    /// still routes key equivalents through `NSApp.mainMenu` while one of our
    /// windows is key. Without a main menu ⌘Q and ⌘W do nothing in Settings or
    /// Welcome, and users resort to Activity Monitor to quit MNotch.
    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: L10n.string("Close Window"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L10n.string("Quit MNotch"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let main = NSMenu()
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    @objc private func screensChanged() {
        notchController?.repositionAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionNoticeTask?.cancel()
        AppServices.shared.stopAll()
    }
}

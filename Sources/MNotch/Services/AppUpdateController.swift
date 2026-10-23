import AppKit
import Foundation
import Sparkle

/// Keeps updater side effects out of tests and local debug builds. A developer
/// can explicitly exercise Sparkle with `MNOTCH_ENABLE_UPDATES=1`.
struct AppUpdateRuntimePolicy: Equatable, Sendable {
    let isRunningTests: Bool
    let isDebugBuild: Bool
    let environment: [String: String]

    var updatesAreEnabled: Bool {
        guard !isRunningTests, environment["MNOTCH_DIAGNOSTIC_RUN"] != "1" else { return false }
        return !isDebugBuild || environment["MNOTCH_ENABLE_UPDATES"] == "1"
    }

    static func installationIsEligible(
        bundleURL: URL,
        applicationsDirectoryIsWritable: Bool
    ) -> Bool {
        let standardized = bundleURL.standardizedFileURL
        return standardized.pathExtension.lowercased() == "app"
            && standardized.deletingLastPathComponent().path == "/Applications"
            && !standardized.path.contains("/AppTranslocation/")
            && applicationsDirectoryIsWritable
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
#if DEBUG
        let debug = true
#else
        let debug = false
#endif
        let processName = ProcessInfo.processInfo.processName
        return Self(
            isRunningTests: environment["XCTestConfigurationFilePath"] != nil
                || processName.contains("Tests"),
            isDebugBuild: debug,
            environment: environment
        )
    }
}

/// Single Sparkle boundary for the app. UI code talks to this adapter instead
/// of importing Sparkle, and the framework never starts in tests/debug unless
/// a developer opts in explicitly.
@MainActor
final class AppUpdateController: NSObject {
    static let shared = AppUpdateController()

    private let environment: [String: String]
    private let bundleURL: URL
    private let runtimePolicy: AppUpdateRuntimePolicy
    private lazy var standardController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var hasStarted = false
    private lazy var installationCoordinator = UpdateInstallationCoordinator.live()
    private var preparationTask: Task<Void, Never>?
    private var postponedInstallHandler: (() -> Void)?
    private var automaticInstallOnQuitHandler: (() -> Void)?
    private var waitingWindow: UpdateWaitWindowController?

    static var sparkleVersion: String {
        Bundle(for: SPUUpdater.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.10.0"
    }

    var isPreparingForInstallation: Bool { preparationTask != nil }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        runtimePolicy: AppUpdateRuntimePolicy? = nil
    ) {
        self.environment = environment
        self.bundleURL = bundleURL.standardizedFileURL
        self.runtimePolicy = runtimePolicy ?? .live(environment: environment)
        super.init()
        // Sparkle retains its delegate weakly. Instantiate only after NSObject
        // initialization has completed and `self` is a valid delegate.
        _ = standardController
    }

    var canCheckForUpdates: Bool {
        runtimePolicy.updatesAreEnabled
            && (postponedInstallHandler != nil || automaticInstallOnQuitHandler != nil
                || (hasStarted && standardController.updater.canCheckForUpdates))
    }

    var automaticallyChecksForUpdates: Bool {
        get { standardController.updater.automaticallyChecksForUpdates }
        set { standardController.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { standardController.updater.automaticallyDownloadsUpdates }
        set { standardController.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? {
        standardController.updater.lastUpdateCheckDate
    }

    func start() {
        guard runtimePolicy.updatesAreEnabled, !hasStarted else { return }
        hasStarted = true
        AppDiagnostics.record(.updates, .started)
        standardController.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        guard isInstalledInApplications else {
            presentMoveToApplicationsAlert()
            return
        }
        if postponedInstallHandler != nil || automaticInstallOnQuitHandler != nil {
            preparePendingInstallation()
        } else {
            standardController.checkForUpdates(nil)
        }
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        if installationCoordinator.state == .prepared { return .terminateNow }
        if preparationTask != nil { return .terminateCancel }
        guard automaticInstallOnQuitHandler != nil || postponedInstallHandler != nil else { return .terminateNow }
        preparePendingInstallation()
        return .terminateCancel
    }

    private func preparePendingInstallation() {
        guard preparationTask == nil,
              let handler = postponedInstallHandler ?? automaticInstallOnQuitHandler else { return }
        if installationCoordinator.hasActiveWork {
            AppDiagnostics.record(.updates, .waitingForWork)
            let waiting = UpdateWaitWindowController { [weak self] in self?.cancelPreparation() }
            waitingWindow = waiting
            waiting.showWindow(nil)
            NSApp.activate()
        }
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await installationCoordinator.prepare(), !Task.isCancelled else {
                waitingWindow?.close()
                waitingWindow = nil
                preparationTask = nil
                return
            }
            waitingWindow?.close()
            waitingWindow = nil
            preparationTask = nil
            postponedInstallHandler = nil
            automaticInstallOnQuitHandler = nil
            AppDiagnostics.record(.updates, .readyToInstall)
            handler()
        }
    }

    private func cancelPreparation() {
        if preparationTask != nil { AppDiagnostics.record(.updates, .cancelled) }
        preparationTask?.cancel()
        // Keep this task until its old continuation finishes so another check
        // cannot have its task/window overwritten by the cancelled run.
        installationCoordinator.cancel()
        waitingWindow?.close()
        waitingWindow = nil
    }

    private var isInstalledInApplications: Bool {
        let parent = bundleURL.deletingLastPathComponent()
        return AppUpdateRuntimePolicy.installationIsEligible(
            bundleURL: bundleURL,
            applicationsDirectoryIsWritable:
                FileManager.default.isWritableFile(atPath: parent.path)
                && FileManager.default.isWritableFile(atPath: bundleURL.path)
        )
    }

    private func presentMoveToApplicationsAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Move MNotch to Applications")
        alert.informativeText = L10n.string(
            "To install updates safely, move MNotch to /Applications and open it again."
        )
        alert.addButton(withTitle: L10n.string("Reveal MNotch"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        }
    }
}

extension AppUpdateController: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        mayPerform updateCheck: SPUUpdateCheck
    ) throws {
        guard isInstalledInApplications else {
            throw NSError(
                domain: "com.mnotch.app.updates",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: L10n.string(
                        "MNotch must be in /Applications before it can check for updates."
                    ),
                ]
            )
        }
    }

    /// Enables a private test feed without changing the signed production
    /// bundle. Nil falls back to SUFeedURL in Info.plist.
    func feedURLString(for updater: SPUUpdater) -> String? {
        environment["MNOTCH_UPDATE_FEED_URL"]
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponedInstallHandler = installHandler
        preparePendingInstallation()
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        automaticInstallOnQuitHandler = immediateInstallHandler
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        AppDiagnostics.record(.updates, .connectionFailed, status: Int32(clamping: (error as NSError).code))
        postponedInstallHandler = nil
        automaticInstallOnQuitHandler = nil
        cancelPreparation()
    }
}

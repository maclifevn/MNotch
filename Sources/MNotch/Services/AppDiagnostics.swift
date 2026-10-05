import AppKit
import Foundation
import UniformTypeIdentifiers
import os

let mnotchLog = Logger(subsystem: "com.mnotch.app", category: "application")

enum DiagnosticComponent: String, Codable, Sendable {
    case application, subprocess, media, claude, codex, agentServer, calendar
    case brightness, keyboardBacklight, lockScreen, updates
}

enum DiagnosticCode: String, Codable, Sendable {
    case started, stopped, exited, timedOut, cancelled, outputLimit, launchFailed
    case connectionFailed, unsupportedOS, waitingForWork, readyToInstall
}

struct DiagnosticEvent: Codable, Sendable {
    let time: Date
    let component: DiagnosticComponent
    let code: DiagnosticCode
    let status: Int32?
    let elapsed: TimeInterval?
}

/// Deliberately accepts enums and numeric metadata only. Raw error messages,
/// commands, paths, titles, tokens and account/session data cannot enter an
/// exported report. The bounded log lives in memory and is never uploaded.
final class DiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []
    private let capacity: Int

    init(capacity: Int = 256) { self.capacity = max(capacity, 1) }

    func append(_ event: DiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        if events.count == capacity { events.removeFirst() }
        events.append(event)
    }

    func snapshot() -> [DiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

enum AppDiagnostics {
    static let buffer = DiagnosticBuffer()

    struct Report: Codable, Sendable {
        let schemaVersion: Int
        let createdAt: Date
        let appVersion: String
        let appBuild: String
        let macOSVersion: String
        let architecture: String
        let runtime: [String: Bool]
        let events: [DiagnosticEvent]
    }

    static func record(
        _ component: DiagnosticComponent, _ code: DiagnosticCode,
        status: Int32? = nil, elapsed: TimeInterval? = nil
    ) {
        let elapsed = elapsed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        buffer.append(.init(time: .now, component: component, code: code, status: status, elapsed: elapsed))
        Logger(subsystem: "com.mnotch.app", category: component.rawValue)
            .info("event=\(code.rawValue, privacy: .public) status=\(status ?? 0) elapsed=\(elapsed ?? 0)")
    }

    static func encode(_ report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    @MainActor
    static func report() -> Report {
        let services = AppServices.shared
        let settings = SettingsStore.shared
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return Report(
            schemaVersion: 1, createdAt: .now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            architecture: "arm64",
            runtime: [
                "mediaEnabled": settings.mediaEnabled,
                "agentEnabled": settings.agentEnabled,
                "calendarEnabled": settings.calendarEnabled,
                "focusEnabled": settings.focusEnabled,
                "shelfEnabled": settings.shelfEnabled,
                "lockEnabled": settings.lockEnabled,
                "soundHUDEnabled": settings.soundHUDEnabled,
                "displayHUDEnabled": settings.displayHUDEnabled,
                "accessibilityGranted": services.accessibility.isGranted,
                "eventTapActive": services.keys.tapActive,
                "calendarAuthorized": services.calendar.authorized,
                "brightnessAvailable": services.brightness.available,
                "keyboardBacklightAvailable": services.backlight.available,
                "mediaPolling": services.media.isPolling,
                "audioRunning": services.audio.isRunning,
                "agentListening": services.agents.serverIsListening,
                "focusAvailable": services.focus.available,
                "bluetoothRunning": services.bluetooth.isRunning,
                "pomodoroRunning": services.pomodoro.isRunning,
                "subprocessesActive": SubprocessLifecycle.shared.activeGroupCount > 0,
                "updatePreparing": AppUpdateController.shared.isPreparingForInstallation,
                "lockCompatibilityVerified": PrivateAPICompatibility.permits(.lockScreen),
            ], events: buffer.snapshot()
        )
    }

    @MainActor
    static func export() {
        NSApp.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MNotch-diagnostics.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try encode(report())
                Task {
                    do {
                        try await Task.detached(priority: .utility) {
                            try data.write(to: url, options: .atomic)
                        }.value
                    } catch { showExportError() }
                }
            } catch { showExportError() }
        }
    }

    @MainActor
    private static func showExportError() {
        let alert = NSAlert()
        alert.messageText = L10n.string("Couldn't save diagnostics. Choose another location and try again.")
        alert.runModal()
    }
}

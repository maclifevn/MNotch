import AppKit
import Foundation
import UniformTypeIdentifiers
import os

let mnotchLog = Logger(subsystem: "com.mnotch.app", category: "application")

enum DiagnosticComponent: String, Codable, Sendable {
    case application, subprocess, media, claude, codex, agentServer, calendar
    case brightness, keyboardBacklight, lockScreen, updates, audio, keyInput, watchdog
}

enum DiagnosticCode: String, Codable, Sendable {
    case started, stopped, exited, timedOut, cancelled, outputLimit, launchFailed
    case connectionFailed, unsupportedOS, waitingForWork, readyToInstall
    case readFailed, writeFailed, listenerFailed, routeChanged, serviceRestarted, tapDisabled
}

struct DiagnosticEvent: Codable, Sendable {
    let time: Date
    let component: DiagnosticComponent
    let code: DiagnosticCode
    let status: Int32?
    let elapsed: TimeInterval?

    var isRoutineSuccess: Bool { code == .exited && status == 0 }
}

/// Deliberately accepts enums and numeric metadata only. Raw error messages,
/// commands, paths, titles, tokens and account/session data cannot enter an
/// exported event. A bounded memory buffer supplements the local disk journal.
final class DiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []
    private let capacity: Int

    init(capacity: Int = 256) { self.capacity = max(capacity, 1) }

    func append(_ event: DiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        if events.count == capacity {
            // Successful media polls are frequent. Keep audio/HAL and other
            // failures useful even if the report is exported much later.
            if let index = events.firstIndex(where: \.isRoutineSuccess) {
                events.remove(at: index)
            } else if event.isRoutineSuccess {
                return
            } else {
                events.removeFirst()
            }
        }
        events.append(event)
    }

    func snapshot() -> [DiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

enum AppDiagnostics {
    static let buffer = DiagnosticBuffer()
    static let persistence = DiagnosticRecorder(
        directory: AppPaths.supportDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory)
    )

    struct Report: Codable, Sendable {
        let schemaVersion: Int
        let createdAt: Date
        let appVersion: String
        let appBuild: String
        let macOSVersion: String
        let architecture: String
        let runtime: [String: Bool]
        let events: [DiagnosticEvent]
        var history: DiagnosticHistory? = nil
    }

    static func record(
        _ component: DiagnosticComponent, _ code: DiagnosticCode,
        status: Int32? = nil, elapsed: TimeInterval? = nil
    ) {
        let elapsed = elapsed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let event = DiagnosticEvent(time: .now, component: component, code: code, status: status, elapsed: elapsed)
        buffer.append(event)
        persistence.record(.init(time: event.time, kind: .event, event: event))
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
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return Report(
            schemaVersion: 1, createdAt: .now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            architecture: "arm64",
            runtime: runtimeState(), events: buffer.snapshot()
        )
    }

    @MainActor
    static func runtimeState() -> [String: Bool] {
        let services = AppServices.shared
        let settings = SettingsStore.shared
        let panels = NSApp?.windows.compactMap { $0 as? NotchPanel } ?? []
        return [
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
                "notchPanelVisible": panels.contains { $0.isVisible },
                "notchInterceptingMouse": panels.contains { $0.isVisible && !$0.ignoresMouseEvents },
                "mouseButtonPressed": NSEvent.pressedMouseButtons != 0,
                "calendarAuthorized": services.calendar.authorized,
                "brightnessAvailable": services.brightness.available,
                "brightnessRunning": services.brightness.isRunning,
                "brightnessResponsive": services.brightness.isResponsive,
                "brightnessControlFailed": services.brightness.hasFailure,
                "keyboardBacklightAvailable": services.backlight.available,
                "mediaPolling": services.media.isPolling,
                "audioRunning": services.audio.isRunning,
                "audioResponsive": services.audio.isResponsive,
                "audioVolumeAvailable": services.audio.canSetVolume,
                "audioMuteAvailable": services.audio.canSetMute,
                "agentListening": services.agents.serverIsListening,
                "focusAvailable": services.focus.available,
                "bluetoothRunning": services.bluetooth.isRunning,
                "pomodoroRunning": services.pomodoro.isRunning,
                "subprocessesActive": SubprocessLifecycle.shared.activeGroupCount > 0,
                "updatePreparing": AppUpdateController.shared.isPreparingForInstallation,
                "lockCompatibilityVerified": PrivateAPICompatibility.permits(.lockScreen),
            ]
    }

    @MainActor
    static func export() {
        NSApp.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MNotch-diagnostics.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let current = report()
            Task {
                var exported = current
                exported.history = await persistence.history()
                do {
                    let report = exported
                    try await Task.detached(priority: .utility) {
                        try encode(report).write(to: url, options: .atomic)
                    }.value
                } catch { showExportError() }
            }
        }
    }

    @MainActor
    private static func showExportError() {
        let alert = NSAlert()
        alert.messageText = L10n.string("Couldn't save diagnostics. Choose another location and try again.")
        alert.runModal()
    }
}

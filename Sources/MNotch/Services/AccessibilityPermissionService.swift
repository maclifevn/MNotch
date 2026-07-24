import AppKit
@preconcurrency import ApplicationServices
import Observation

enum AccessibilityRequirement {
    static func isRequired(
        granted: Bool,
        soundHUDEnabled: Bool,
        displayHUDEnabled: Bool
    ) -> Bool {
        !granted && (soundHUDEnabled || displayHUDEnabled)
    }
}

/// Single source of truth for the Accessibility TCC grant. The service polls
/// lightly while a feature needs the grant so it detects both granting and
/// revocation, and also refreshes whenever MNotch becomes active again.
@MainActor
@Observable
final class AccessibilityPermissionService {
    private(set) var isGranted = AXIsProcessTrusted()

    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var monitoringNeeded = false

    var isRequiredForEnabledFeatures: Bool {
        AccessibilityRequirement.isRequired(
            granted: isGranted,
            soundHUDEnabled: SettingsStore.shared.soundHUDEnabled,
            displayHUDEnabled: SettingsStore.shared.displayHUDEnabled
        )
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        updateTimer()
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
    }

    func setMonitoringNeeded(_ needed: Bool) {
        guard monitoringNeeded != needed else { return }
        monitoringNeeded = needed
        updateTimer()
    }

    func refresh() {
        let granted = AXIsProcessTrusted()
        guard granted != isGranted else {
            updateTimer()
            return
        }
        isGranted = granted
        updateTimer()
        onChange?(granted)
    }

    func requestAccess() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
        updateTimer()
    }

    private func updateTimer() {
        // Keep monitoring after a grant. TCC does not publish a public change
        // notification when the user flips MNotch off in System Settings, and
        // waiting for app activation leaves a global event tap alive too long.
        let shouldPoll = started && monitoringNeeded
        guard shouldPoll != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard shouldPoll else { return }

        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

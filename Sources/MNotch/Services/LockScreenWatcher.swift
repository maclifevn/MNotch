import AppKit
import IOKit.pwr_mgt

enum LockPresentationPolicy {
    static func shouldElevateNotch(isLocked: Bool, featureEnabled: Bool) -> Bool {
        isLocked && featureEnabled
    }
}

/// Lock/unlock sounds, the keep-awake assertion, and the lock screen overlay
/// (widgets + Now Playing card drawn above the shield window).
@MainActor
final class LockScreenWatcher {
    private var assertionID: IOPMAssertionID = 0
    private var assertionActive = false

    private(set) var isLocked = false
    private(set) var saverRunning = false

    private let overlay = LockOverlayController()
    private var observers: [NSObjectProtocol] = []

    /// Tells the window controller whether it should use the private lock-space
    /// path. This is deliberately gated by the Lock Screen feature: a disabled
    /// optional feature must never touch WindowServer's private space APIs.
    var onLockPresentationChanged: ((Bool) -> Void)?

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.screenLocked() }
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.screenUnlocked() }
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.saverRunning = true
                self?.refreshOverlay()
            }
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstop"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.saverRunning = false
                self?.refreshOverlay()
            }
        })
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        releaseAssertion()
        overlay.setVisible(false)
    }

    /// Apply live Settings changes without waiting for the next lock/saver event.
    func reconfigure() {
        updateLockPresentation()
        refreshOverlay()
        overlay.reconfigure()
        if !SettingsStore.shared.lockEnabled {
            releaseAssertion()
        }
    }

    private func refreshOverlay() {
        let settings = SettingsStore.shared
        let wanted = settings.lockEnabled
            && (isLocked || (saverRunning && settings.lockShowOnScreenSaver))
        overlay.setVisible(wanted)
    }

    private func screenLocked() {
        isLocked = true
        updateLockPresentation()
        refreshOverlay()

        let settings = SettingsStore.shared
        // Sounds and power assertions are part of the Lock Screen feature,
        // not global lock side effects. Disabled must mean fully inert even if
        // a subordinate preference was saved from an earlier configuration.
        guard settings.lockEnabled else {
            releaseAssertion()
            return
        }
        if settings.lockSoundOnLock {
            SoundPlayer.play(.lock)
        }
        let minutes = settings.lockKeepAwake
        guard minutes > 0 else { return }
        releaseAssertion()
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            "MNotch keep awake after lock" as CFString,
            nil, nil, nil,
            minutes * 60,
            kIOPMAssertionTimeoutActionRelease as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            assertionActive = true
        }
    }

    private func screenUnlocked() {
        isLocked = false
        updateLockPresentation()
        refreshOverlay()

        if SettingsStore.shared.lockEnabled,
           SettingsStore.shared.lockSoundOnUnlock {
            SoundPlayer.play(.unlock)
        }
        releaseAssertion()
    }

    private func updateLockPresentation() {
        onLockPresentationChanged?(LockPresentationPolicy.shouldElevateNotch(
            isLocked: isLocked,
            featureEnabled: SettingsStore.shared.lockEnabled
        ))
    }

    private func releaseAssertion() {
        guard assertionActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionActive = false
    }
}

import AppKit
import IOKit.pwr_mgt

/// Lock/unlock sounds, the keep-awake assertion, and the lock screen overlay
/// (widgets + Now Playing card drawn above the shield window).
@MainActor
final class LockScreenWatcher {
    private var assertionID: IOPMAssertionID = 0
    private var assertionActive = false

    private(set) var isLocked = false
    private(set) var saverRunning = false

    private let overlay = LockOverlayController()

    /// Fired on lock/unlock so the notch panels can (un)elevate above the shield.
    var onLockStateChanged: ((Bool) -> Void)?

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.screenLocked() }
        }
        center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.screenUnlocked() }
        }
        center.addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.saverRunning = true
                self?.refreshOverlay()
            }
        }
        center.addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstop"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.saverRunning = false
                self?.refreshOverlay()
            }
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
        onLockStateChanged?(true)
        refreshOverlay()

        let settings = SettingsStore.shared
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
        onLockStateChanged?(false)
        refreshOverlay()

        if SettingsStore.shared.lockSoundOnUnlock {
            SoundPlayer.play(.unlock)
        }
        releaseAssertion()
    }

    private func releaseAssertion() {
        guard assertionActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionActive = false
    }
}

import AppKit
import IOKit.pwr_mgt

/// Lock/unlock sounds and the keep-awake assertion (keeps the display on for
/// N minutes after locking, timeout-released automatically).
@MainActor
final class LockScreenWatcher {
    private var assertionID: IOPMAssertionID = 0
    private var assertionActive = false

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
    }

    private func screenLocked() {
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

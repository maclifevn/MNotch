import AppKit

/// Single owner of all long-lived services; shared across notch panels.
/// Routes system-key events to actions and broadcasts HUDs to the panels.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let media = MediaRemoteService()
    let accessibility = AccessibilityPermissionService()
    let audio = AudioOutputService()
    let keys = KeyInterceptor()
    let brightness = BrightnessService()
    let backlight = KeyboardBacklightService()
    let power = PowerSourceService()
    let bluetooth = BluetoothWatcher()
    let calendar = CalendarService()
    let occlusion = OcclusionWatcher()
    let focus = FocusWatcher()
    let lockScreen = LockScreenWatcher()
    let agents = AgentMonitorService()
    let quota = QuotaService()
    let notifications = NotificationMirrorService()

    /// Set by NotchWindowController; opens the Agent tab for a request.
    var expandAgent: (() -> Void)?
    /// Set by NotchWindowController; collapses if no request remains.
    var collapseIfIdle: (() -> Void)?
    /// Removes a stale permission reminder as soon as TCC grants access.
    var dismissAccessibilityNotice: (() -> Void)?

    enum NotificationCategory {
        case battery, connectivity, display, sound
    }

    /// Allowed-notifications filter (Settings → Focus) while a focus is on.
    func allowedNow(_ category: NotificationCategory) -> Bool {
        let settings = SettingsStore.shared

        // While the screen is locked, Settings → Lock Screen → Allowed
        // Notifications decides what may appear over the shield.
        if lockScreen.isLocked {
            let lockAllowed = switch category {
            case .battery: settings.lockAllowBattery
            case .connectivity: settings.lockAllowConnectivity
            case .display: settings.lockAllowDisplay
            case .sound: settings.lockAllowSound
            }
            guard lockAllowed else { return false }
        }

        guard settings.focusEnabled, focus.isFocused else { return true }
        return switch category {
        case .battery: settings.focusAllowBattery
        case .connectivity: settings.focusAllowConnectivity
        case .display: settings.focusAllowDisplay
        case .sound: settings.focusAllowSound
        }
    }

    /// Set by NotchWindowController; fans HUDs out to every panel.
    var showHUD: ((HUDKind, Double, Bool) -> Void)?
    /// Set by NotchWindowController; fans pops out to every panel.
    var showPop: ((PopKind) -> Void)?

    private var startedAt = Date.distantPast
    private var lastObservedVolume: Double?
    private var lastObservedMuted: Bool?
    private var started = false
    private lazy var featureCoordinator = FeatureCoordinator(services: self)
    private enum SuspensionReason: Hashable { case displaySleep }
    private var suspensionReasons: Set<SuspensionReason> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservers: [NSObjectProtocol] = []

    private init() {}

    func startAll() {
        guard !started else { return }
        started = true
        startedAt = Date()
        accessibility.onChange = { [weak self] granted in
            guard let self else { return }
            if granted {
                self.keys.allowRestartAfterPermissionGrant()
            }
            self.featureCoordinator.accessibilityDidChange(granted)
            if granted {
                self.dismissAccessibilityNotice?()
            } else if self.accessibility.isRequiredForEnabledFeatures {
                self.showPop?(.accessibility)
            }
        }
        accessibility.start()
        // Observe-mode brightness HUD (mirrors the system OSD until the
        // event tap has Accessibility and consumes the keys itself).
        brightness.onChanged = { [weak self] value in
            guard let self,
                  SettingsStore.shared.displayHUDEnabled,
                  !self.keys.tapActive,
                  self.allowedNow(.display)
            else { return }
            self.showHUD?(.brightness, value, false)
        }
        keys.handler = { [weak self] key, keyDown, isRepeat, modifiers in
            self?.handleSystemKey(key, keyDown: keyDown, modifiers: modifiers) ?? false
        }
        keys.onInterruption = { [weak self] reason in
            mnotchLog.error("event tap interrupted (\(reason.rawValue)); staying fail-open")
            // This is intentionally refresh-only. If TCC still reports true
            // after a timeout, the safety latch keeps the tap off rather than
            // risking a global disable/re-enable loop.
            self?.accessibility.refresh()
        }

        power.onPowerEvent = { [weak self] event in
            let settings = SettingsStore.shared
            guard settings.batteryEnabled, self?.allowedNow(.battery) != false else { return }
            switch event {
            case .pluggedIn(let percentage):
                self?.showPop?(.charging(percentage: percentage))
            case .unplugged(let percentage):
                _ = percentage // No pop on unplug; matches Alcove's restraint.
            case .lowBattery(let percentage):
                guard settings.batteryWarnLow else { return }
                self?.showPop?(.lowBattery(percentage: percentage))
                if settings.batterySoundOnLow {
                    SoundPlayer.play(.lowBattery)
                }
            case .lowPowerMode(let on):
                guard settings.batteryNotifyLowPower else { return }
                self?.showPop?(.lowPower(on: on))
            }
        }

        bluetooth.onConnect = { [weak self] name, symbol, battery in
            guard SettingsStore.shared.connectivityEnabled,
                  self?.allowedNow(.connectivity) != false else { return }
            self?.showPop?(.device(name: name, symbol: symbol, battery: battery))
        }
        bluetooth.onLowBattery = { [weak self] name, symbol, battery in
            guard self?.allowedNow(.connectivity) != false else { return }
            self?.showPop?(.device(name: name, symbol: symbol, battery: battery))
        }

        // Agent monitor: permission requests auto-expand the notch into the
        // Agent tab; idle prompts and turn-completions fire pops + sounds.
        agents.onRequest = { [weak self] session in
            guard let self else { return }
            let settings = SettingsStore.shared
            guard settings.agentEnabled else { return }
            // If the agent's own terminal is frontmost, the user is looking at
            // it — let the native prompt handle it there and keep the notch
            // quiet. The notch only takes over when they've tabbed away. Users
            // who always want the notch can turn this off.
            if settings.agentDeferToTerminal, self.agents.terminalIsFrontmost(session) {
                self.agents.deferToTerminal(session)
                return
            }
            if settings.agentSound { SoundPlayer.play(.agentAttention) }
            if settings.agentAutoExpand { self.expandAgent?() }
        }
        agents.onAttention = { [weak self] session in
            guard SettingsStore.shared.agentEnabled else { return }
            if SettingsStore.shared.agentSound { SoundPlayer.play(.agentAttention) }
            self?.showPop?(.agent(name: session.folderName, kind: session.kind, needsInput: true))
        }
        agents.onDone = { [weak self] session in
            guard SettingsStore.shared.agentEnabled else { return }
            if SettingsStore.shared.agentSound { SoundPlayer.play(.agentDone) }
            self?.showPop?(.agent(name: session.folderName, kind: session.kind, needsInput: false))
        }
        agents.onRequestResolved = { [weak self] in
            self?.collapseIfIdle?()
        }
        notifications.onNotification = { [weak self] item in
            guard let self, SettingsStore.shared.notifMirrorEnabled else { return }
            // Respect Focus / Do Not Disturb: macOS still records notifications
            // to the store while suppressing their banners, so don't resurface
            // them on the notch when a Focus is active.
            guard !self.focus.isFocused else { return }
            self.showPop?(.systemNotification(
                bundleID: item.bundleID,
                app: item.appName,
                title: item.title,
                body: item.body
            ))
        }
        // Claude usage comes solely from the local CLI. Refresh installed hook
        // scripts and migrate the retired status-line quota wrapper if present.
        ClaudeHookInstaller.refreshScripts()

        focus.onChange = { [weak self] old, new in
            let settings = SettingsStore.shared
            guard settings.focusEnabled else { return }
            if self?.lockScreen.isLocked == true, !settings.lockAllowFocus { return }
            if let new {
                self?.showPop?(.focus(name: new.name, symbol: new.symbol, on: true))
                if settings.focusSoundOnSleep,
                   new.identifier.localizedCaseInsensitiveContains("sleep") {
                    SoundPlayer.play(.sleep)
                }
            } else if let old {
                self?.showPop?(.focus(name: old.name, symbol: old.symbol, on: false))
            }
        }

        calendar.onPeek = { [weak self] item, startingNow in
            self?.showPop?(.event(
                title: item.title,
                red: item.colorRed,
                green: item.colorGreen,
                blue: item.colorBlue,
                startingNow: startingNow,
                start: item.start
            ))
            if SettingsStore.shared.calendarSoundOnEvent {
                SoundPlayer.play(.event)
            }
        }
        calendar.onChime = {
            SoundPlayer.play(.chime)
        }
        // Observe-only fallback (no Accessibility yet): mirror volume changes
        // from any source as a HUD. Redundant-but-harmless when the tap is
        // active, since the key handler already showed the same value.
        audio.onVolumeChanged = { [weak self] volume, muted in
            guard let self, SettingsStore.shared.soundHUDEnabled else { return }
            guard Date().timeIntervalSince(self.startedAt) > 3 else { return }
            // Key on BOTH values so a mute-only transition (unmute at the
            // same volume) still shows the HUD.
            let changed = self.lastObservedVolume != volume
                || self.lastObservedMuted != muted
            self.lastObservedVolume = volume
            self.lastObservedMuted = muted
            guard changed, self.allowedNow(.sound) else { return }
            self.showHUD?(.volume, muted ? 0 : volume, muted)
        }

        installWorkspaceLifecycleObservers()
        featureCoordinator.start()
    }

    func stopAll() {
        guard started else { return }
        started = false
        removeWorkspaceLifecycleObservers()
        featureCoordinator.stop()
        accessibility.stop()
    }

    func setAgentMonitoringEnabled(_ enabled: Bool) {
        // The setting is the source of truth; keep this compatibility entry
        // point for onboarding/Settings and apply it synchronously.
        if SettingsStore.shared.agentEnabled != enabled {
            SettingsStore.shared.agentEnabled = enabled
        }
        featureCoordinator.refresh()
    }

    private func installWorkspaceLifecycleObservers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ reason: SuspensionReason, active: Bool) {
            workspaceObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.setSuspension(reason, active: active) }
            })
        }
        observe(NSWorkspace.screensDidSleepNotification, .displaySleep, active: true)
        observe(NSWorkspace.screensDidWakeNotification, .displaySleep, active: false)

        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.featureCoordinator.applicationDidBecomeActive() }
        })
    }

    private func removeWorkspaceLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        applicationObservers.removeAll()
        suspensionReasons.removeAll()
    }

    private func setSuspension(_ reason: SuspensionReason, active: Bool) {
        if active {
            suspensionReasons.insert(reason)
        } else {
            suspensionReasons.remove(reason)
        }
        featureCoordinator.setSuspended(!suspensionReasons.isEmpty)
    }

    private func handleSystemKey(
        _ key: SystemKey,
        keyDown: Bool,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let settings = SettingsStore.shared
        let fine = modifiers.contains(.shift) && modifiers.contains(.option)
        switch key {
        case .soundUp, .soundDown:
            guard settings.soundHUDEnabled else { return false }
            if keyDown {
                enqueueSystemKeyAction(key, fine: fine)
            }
            return true
        case .mute:
            guard settings.soundHUDEnabled else { return false }
            if keyDown {
                enqueueSystemKeyAction(key, fine: fine)
            }
            return true
        case .brightnessUp, .brightnessDown:
            // If we can't set brightness ourselves, let the system handle the
            // key (and show its own OSD) rather than breaking the feature.
            guard settings.displayHUDEnabled, brightness.available else { return false }
            if keyDown {
                enqueueSystemKeyAction(key, fine: fine)
            }
            return true
        case .illuminationUp, .illuminationDown:
            guard settings.displayHUDEnabled, backlight.available else { return false }
            if keyDown {
                enqueueSystemKeyAction(key, fine: fine)
            }
            return true
        }
    }

    /// The global event-tap callback must return immediately. Hardware I/O and
    /// SwiftUI state changes run on the next main-actor turn, after the event
    /// has already been consumed or passed through.
    private func enqueueSystemKeyAction(_ key: SystemKey, fine: Bool) {
        Task { @MainActor [weak self] in
            self?.performSystemKeyAction(key, fine: fine)
        }
    }

    private func performSystemKeyAction(_ key: SystemKey, fine: Bool) {
        let settings = SettingsStore.shared
        switch key {
        case .soundUp, .soundDown:
            guard settings.soundHUDEnabled else { return }
            let step = (fine ? 1.0 / 64 : 1.0 / 16) * (key == .soundUp ? 1 : -1)
            let newVolume = min(max(audio.volume + step, 0), 1)
            audio.setVolume(newVolume)
            if allowedNow(.sound) {
                showHUD?(.volume, audio.muted ? 0 : newVolume, audio.muted)
            }
        case .mute:
            guard settings.soundHUDEnabled else { return }
            audio.setMuted(!audio.muted)
            if allowedNow(.sound) {
                showHUD?(.volume, audio.muted ? 0 : audio.volume, audio.muted)
            }
        case .brightnessUp, .brightnessDown:
            guard settings.displayHUDEnabled, brightness.available else { return }
            let newValue = brightness.step(up: key == .brightnessUp, fine: fine)
            if allowedNow(.display) {
                showHUD?(.brightness, newValue, false)
            }
        case .illuminationUp, .illuminationDown:
            guard settings.displayHUDEnabled, backlight.available else { return }
            let newValue = backlight.step(up: key == .illuminationUp)
            if allowedNow(.display) {
                showHUD?(.keyboardBacklight, newValue, false)
            }
        }
    }
}

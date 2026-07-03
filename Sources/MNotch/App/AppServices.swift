import EventKit
import AppKit

/// Single owner of all long-lived services; shared across notch panels.
/// Routes system-key events to actions and broadcasts HUDs to the panels.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let media = MediaRemoteService()
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

    enum NotificationCategory {
        case battery, connectivity, display, sound
    }

    /// Allowed-notifications filter (Settings → Focus) while a focus is on.
    func allowedNow(_ category: NotificationCategory) -> Bool {
        guard focus.isFocused else { return true }
        let settings = SettingsStore.shared
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

    private init() {}

    func startAll() {
        startedAt = Date()
        media.start()
        audio.start()
        brightness.start()
        backlight.start()

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
        brightness.startObserving()

        keys.handler = { [weak self] key, keyDown, isRepeat, modifiers in
            self?.handleSystemKey(key, keyDown: keyDown, modifiers: modifiers) ?? false
        }
        keys.start()

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
        power.start()

        bluetooth.onConnect = { [weak self] name, symbol, battery in
            guard SettingsStore.shared.connectivityEnabled,
                  self?.allowedNow(.connectivity) != false else { return }
            self?.showPop?(.device(name: name, symbol: symbol, battery: battery))
        }
        bluetooth.onLowBattery = { [weak self] name, symbol, battery in
            guard self?.allowedNow(.connectivity) != false else { return }
            self?.showPop?(.device(name: name, symbol: symbol, battery: battery))
        }
        bluetooth.start()
        occlusion.start()
        lockScreen.start()

        focus.onChange = { [weak self] old, new in
            let settings = SettingsStore.shared
            guard settings.focusEnabled else { return }
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
        focus.start()

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
        // Start eagerly only when access was already granted (no TCC prompt
        // at launch); otherwise the first calendar UI touch requests it.
        if SettingsStore.shared.calendarEnabled,
           EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            calendar.ensureStarted()
        }

        // Observe-only fallback (no Accessibility yet): mirror volume changes
        // from any source as a HUD. Redundant-but-harmless when the tap is
        // active, since the key handler already showed the same value.
        audio.onVolumeChanged = { [weak self] volume, muted in
            guard let self, SettingsStore.shared.soundHUDEnabled else { return }
            guard Date().timeIntervalSince(self.startedAt) > 3 else { return }
            guard self.lastObservedVolume != volume || muted else {
                self.lastObservedVolume = volume
                return
            }
            self.lastObservedVolume = volume
            guard self.allowedNow(.sound) else { return }
            self.showHUD?(.volume, muted ? 0 : volume, muted)
        }
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
                let step = (fine ? 1.0 / 64 : 1.0 / 16) * (key == .soundUp ? 1 : -1)
                let newVolume = min(max(audio.volume + step, 0), 1)
                audio.setVolume(newVolume)
                if allowedNow(.sound) {
                    showHUD?(.volume, audio.muted ? 0 : newVolume, audio.muted)
                }
            }
            return true
        case .mute:
            guard settings.soundHUDEnabled else { return false }
            if keyDown {
                audio.setMuted(!audio.muted)
                if allowedNow(.sound) {
                    showHUD?(.volume, audio.muted ? 0 : audio.volume, audio.muted)
                }
            }
            return true
        case .brightnessUp, .brightnessDown:
            // If we can't set brightness ourselves, let the system handle the
            // key (and show its own OSD) rather than breaking the feature.
            guard settings.displayHUDEnabled, brightness.available else { return false }
            if keyDown {
                let newValue = brightness.step(up: key == .brightnessUp, fine: fine)
                if allowedNow(.display) {
                    showHUD?(.brightness, newValue, false)
                }
            }
            return true
        case .illuminationUp, .illuminationDown:
            guard settings.displayHUDEnabled, backlight.available else { return false }
            if keyDown {
                let newValue = backlight.step(up: key == .illuminationUp)
                if allowedNow(.display) {
                    showHUD?(.keyboardBacklight, newValue, false)
                }
            }
            return true
        }
    }
}

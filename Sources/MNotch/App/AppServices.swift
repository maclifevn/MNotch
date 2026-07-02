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

        keys.handler = { [weak self] key, keyDown, isRepeat, modifiers in
            self?.handleSystemKey(key, keyDown: keyDown, modifiers: modifiers) ?? false
        }
        keys.start()

        power.onPowerEvent = { [weak self] event in
            switch event {
            case .pluggedIn(let percentage):
                self?.showPop?(.charging(percentage: percentage))
            case .unplugged(let percentage):
                _ = percentage // No pop on unplug; matches Alcove's restraint.
            case .lowBattery(let percentage):
                self?.showPop?(.lowBattery(percentage: percentage))
            }
        }
        power.start()

        bluetooth.onConnect = { [weak self] name, symbol, battery in
            self?.showPop?(.device(name: name, symbol: symbol, battery: battery))
        }
        bluetooth.start()

        // Observe-only fallback (no Accessibility yet): mirror volume changes
        // from any source as a HUD. Redundant-but-harmless when the tap is
        // active, since the key handler already showed the same value.
        audio.onVolumeChanged = { [weak self] volume, muted in
            guard let self else { return }
            guard Date().timeIntervalSince(self.startedAt) > 3 else { return }
            guard self.lastObservedVolume != volume || muted else {
                self.lastObservedVolume = volume
                return
            }
            self.lastObservedVolume = volume
            self.showHUD?(.volume, muted ? 0 : volume, muted)
        }
    }

    private func handleSystemKey(
        _ key: SystemKey,
        keyDown: Bool,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let fine = modifiers.contains(.shift) && modifiers.contains(.option)
        switch key {
        case .soundUp, .soundDown:
            if keyDown {
                let step = (fine ? 1.0 / 64 : 1.0 / 16) * (key == .soundUp ? 1 : -1)
                let newVolume = min(max(audio.volume + step, 0), 1)
                audio.setVolume(newVolume)
                showHUD?(.volume, audio.muted ? 0 : newVolume, audio.muted)
            }
            return true
        case .mute:
            if keyDown {
                audio.setMuted(!audio.muted)
                showHUD?(.volume, audio.muted ? 0 : audio.volume, audio.muted)
            }
            return true
        case .brightnessUp, .brightnessDown:
            // If we can't set brightness ourselves, let the system handle the
            // key (and show its own OSD) rather than breaking the feature.
            guard brightness.available else { return false }
            if keyDown {
                let newValue = brightness.step(up: key == .brightnessUp, fine: fine)
                showHUD?(.brightness, newValue, false)
            }
            return true
        case .illuminationUp, .illuminationDown:
            guard backlight.available else { return false }
            if keyDown {
                let newValue = backlight.step(up: key == .illuminationUp)
                showHUD?(.keyboardBacklight, newValue, false)
            }
            return true
        }
    }
}

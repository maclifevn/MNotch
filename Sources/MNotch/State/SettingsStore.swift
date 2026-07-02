import AppKit
import Observation
import ServiceManagement

/// UserDefaults-backed feature toggles.
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    var mediaEnabled: Bool {
        didSet { UserDefaults.standard.set(mediaEnabled, forKey: "feature.media") }
    }
    var hudEnabled: Bool {
        didSet { UserDefaults.standard.set(hudEnabled, forKey: "feature.hud") }
    }
    var batteryEnabled: Bool {
        didSet { UserDefaults.standard.set(batteryEnabled, forKey: "feature.battery") }
    }
    var bluetoothEnabled: Bool {
        didSet { UserDefaults.standard.set(bluetoothEnabled, forKey: "feature.bluetooth") }
    }
    var calendarEnabled: Bool {
        didSet { UserDefaults.standard.set(calendarEnabled, forKey: "feature.calendar") }
    }
    var shelfEnabled: Bool {
        didSet { UserDefaults.standard.set(shelfEnabled, forKey: "feature.shelf") }
    }
    var fakeNotchOnExternal: Bool {
        didSet {
            UserDefaults.standard.set(fakeNotchOnExternal, forKey: "display.fakeNotch")
            onDisplayConfigChanged?()
        }
    }
    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    /// Set by NotchWindowController to rebuild panels on display toggles.
    @ObservationIgnored
    var onDisplayConfigChanged: (() -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        func flag(_ key: String, default value: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
        }
        mediaEnabled = flag("feature.media", default: true)
        hudEnabled = flag("feature.hud", default: true)
        batteryEnabled = flag("feature.battery", default: true)
        bluetoothEnabled = flag("feature.bluetooth", default: true)
        calendarEnabled = flag("feature.calendar", default: true)
        shelfEnabled = flag("feature.shelf", default: true)
        fakeNotchOnExternal = flag("display.fakeNotch", default: false)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            mnotchLog.error("launch-at-login toggle failed: \(error)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

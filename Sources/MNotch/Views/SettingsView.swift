import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Features") {
                Toggle("Now Playing", isOn: $settings.mediaEnabled)
                Toggle("Volume & brightness HUD", isOn: $settings.hudEnabled)
                Toggle("Battery alerts", isOn: $settings.batteryEnabled)
                Toggle("Bluetooth device popups", isOn: $settings.bluetoothEnabled)
                Toggle("Calendar", isOn: $settings.calendarEnabled)
                Toggle("File shelf", isOn: $settings.shelfEnabled)
            }
            Section("Displays") {
                Toggle("Fake notch on external displays", isOn: $settings.fakeNotchOnExternal)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                LabeledContent("HUD key interception") {
                    Text(AppServices.shared.keys.tapActive
                        ? "Active"
                        : "Grant Accessibility in System Settings, then relaunch")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 380)
    }
}

/// Hand-managed settings window (no SwiftUI Settings scene in an SPM binary).
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 380),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "MNotch Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

import AppKit
import SwiftUI

struct GeneralPane: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Hide in fullscreen", isOn: $settings.hideInFullscreen)
                Toggle("Hide in mission control", isOn: $settings.hideInMissionControl)
                Toggle("Hide while gaming", isOn: $settings.hideWhileGaming)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Hide from screen capture", isOn: $settings.hideFromScreenCapture)
                    Text("Only affects legacy capture APIs; modern recorders capture the full display.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Toggle("Force simulated notch", isOn: $settings.forceSimulatedNotch)
                Picker("Display on", selection: $settings.displayTarget) {
                    Text("All displays").tag("all")
                    Text("Main display").tag("main")
                    Text("Built-in display").tag("builtIn")
                    ForEach(NSScreen.screens, id: \.displayID) { screen in
                        Text(screen.localizedName).tag(String(screen.displayID))
                    }
                }
            }

            Section("Idle Activity") {
                Toggle(isOn: $settings.idleMostRecent) {
                    Label("Most Recent", systemImage: "clock.arrow.circlepath")
                }
                IconCardPicker(
                    selection: $settings.idleActivity,
                    options: IdleActivity.allCases,
                    label: { activity in
                        switch activity {
                        case .none: "None"
                        case .playing: "Playing"
                        case .calendar: "Calendar"
                        case .duo: "Duo"
                        }
                    },
                    symbol: { activity in
                        switch activity {
                        case .none: "nosign"
                        case .playing: "play.rectangle.fill"
                        case .calendar: "calendar"
                        case .duo: "rectangle.on.rectangle.fill"
                        }
                    }
                )
                .disabled(settings.idleMostRecent)
            }

            Section("Behaviour") {
                Toggle("Contrast outline", isOn: $settings.contrastOutline)
                Toggle("Progressive blur", isOn: $settings.progressiveBlur)
                Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Expand on hover", isOn: $settings.expandOnHover)
                    Text("Off: hover only grows the notch; click to open.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Gestures") {
                Toggle("Natural movement", isOn: $settings.gestureNatural)
                Toggle("Swipe to toggle open", isOn: $settings.gestureToggleOpen)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Swipe to cycle activity", isOn: $settings.gestureCycleActivity)
                    Text("Horizontal swipe when no media is playing.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Toggle("Swipe to dismiss activity", isOn: $settings.gestureDismissActivity)
                Toggle("Swipe to skip media", isOn: $settings.gestureSkipMedia)
            }

            Section("Tuning") {
                SliderRow(
                    title: "Notch width",
                    value: $settings.notchWidthOffset,
                    range: -20...40,
                    step: 2
                ) { "\(Int($0)) px" }
                SliderRow(
                    title: "Notch height",
                    value: $settings.notchHeightOffset,
                    range: -8...24,
                    step: 2
                ) { "\(Int($0)) px" }
            }
        }
        .formStyle(.grouped)
    }
}

struct BatteryPane: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.batteryEnabled) {
                    Label("Battery", systemImage: "bolt.fill")
                }
                SliderRow(
                    title: "Duration",
                    value: $settings.batteryDuration,
                    range: 1...10,
                    step: 0.5
                ) { String(format: "%.1f s", $0) }
                Toggle("Notify on low power mode", isOn: $settings.batteryNotifyLowPower)
                Toggle("Warn on low battery", isOn: $settings.batteryWarnLow)
                SliderRow(
                    title: "Low battery threshold",
                    value: $settings.batteryLowThreshold,
                    range: 5...50,
                    step: 5
                ) { "\(Int($0)) %" }
                SoundToggleRow(
                    title: "Play sound on low battery",
                    isOn: $settings.batterySoundOnLow,
                    effect: .lowBattery
                )
                Toggle("Hide label", isOn: $settings.batteryHideLabel)
                Toggle("Hide percentage", isOn: $settings.batteryHidePercentage)
            }
        }
        .formStyle(.grouped)
    }
}

struct ConnectivityPane: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.connectivityEnabled) {
                    Label("Connectivity", systemImage: "headphones")
                }
                SliderRow(
                    title: "Duration",
                    value: $settings.connectivityDuration,
                    range: 1...10,
                    step: 0.5
                ) { String(format: "%.1f s", $0) }
                Toggle("Warn on low battery", isOn: $settings.connectivityWarnLow)
                SliderRow(
                    title: "Low battery threshold",
                    value: $settings.connectivityLowThreshold,
                    range: 10...50,
                    step: 5
                ) { "\(Int($0)) %" }
                SoundToggleRow(
                    title: "Play sound on low battery",
                    isOn: $settings.connectivitySoundOnLow,
                    effect: .deviceLow
                )
            }
            Section {
                LabeledContent("Device visuals") {
                    Text("Symbols")
                        .foregroundStyle(.secondary)
                }
                Text("Alcove's 3D models require bundled USDZ assets and aren't available here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

struct FocusPane: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.focusEnabled) {
                    Label("Focus", systemImage: "moon.fill")
                }
                if !AppServices.shared.focus.available {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Needs Full Disk Access to read Focus state.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                            )!)
                        }
                        .controlSize(.small)
                    }
                }
                SliderRow(
                    title: "Duration",
                    value: $settings.focusDuration,
                    range: 1...10,
                    step: 0.5
                ) { String(format: "%.1f s", $0) }
                SoundToggleRow(
                    title: "Play sound on sleep focus",
                    isOn: $settings.focusSoundOnSleep,
                    effect: .sleep
                )
                Toggle("Replace waveform during focus", isOn: $settings.focusReplaceWaveform)
                Toggle("Hide label", isOn: $settings.focusHideLabel)
            }
            Section("Allowed Notifications") {
                Toggle(isOn: $settings.focusAllowBattery) {
                    Label("Battery", systemImage: "bolt.fill")
                }
                Toggle(isOn: $settings.focusAllowConnectivity) {
                    Label("Connectivity", systemImage: "headphones")
                }
                Toggle(isOn: $settings.focusAllowDisplay) {
                    Label("Display", systemImage: "sun.max.fill")
                }
                Toggle(isOn: $settings.focusAllowSound) {
                    Label("Sound", systemImage: "speaker.wave.2.fill")
                }
            }
        }
        .formStyle(.grouped)
    }
}

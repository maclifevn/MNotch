import AppKit
import SwiftUI

struct GeneralPane: View {
    @Bindable var settings = SettingsStore.shared
    private let accessibility = AppServices.shared.accessibility
    @State private var hasPhysicalNotch = Self.detectPhysicalNotch()

    var body: some View {
        Form {
            Section("Language") {
                Picker("Application language", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                if settings.languageRestartRequired {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Restart MNotch to apply the new language.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Restart MNotch") {
                            ApplicationRestart.restart()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            if !accessibility.isGranted {
                Section("Permissions") {
                    AccessibilityPermissionRow()
                }
            }

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
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Simulated notch", isOn: simulatedNotchBinding)
                        // With no physical notch, disabling the effective state
                        // would make the app's only UI disappear. The runtime
                        // fallback is mandatory, so reflect that honestly.
                        .disabled(!hasPhysicalNotch)
                    Text(simulatedNotchExplanation)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Picker("Display on", selection: $settings.displayTarget) {
                    Text("All displays").tag("all")
                    Text("Main display").tag("main")
                    Text("Built-in display").tag("builtIn")
                    ForEach(NSScreen.screens, id: \.displayID) { screen in
                        Text(screen.localizedName).tag(String(screen.displayID))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Hide menu bar icon", isOn: $settings.hideMenuBarIcon)
                    Text("Settings stays reachable from the gear tab in the notch, and Quit is below.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Spacer()
                    Button("Quit MNotch") { NSApp.terminate(nil) }
                        .controlSize(.small)
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
                .onChange(of: settings.idleActivity) { _, activity in
                    // Picking Calendar/Duo must kick off the EventKit access
                    // request, or on a fresh install the choice silently does
                    // nothing until the calendar tab happens to open.
                    if activity == .calendar || activity == .duo {
                        AppServices.shared.calendar.ensureStarted()
                    }
                }
                .onChange(of: settings.idleMostRecent) { _, on in
                    if on {
                        AppServices.shared.calendar.ensureStarted()
                    }
                }
            }

            Section("Behaviour") {
                Toggle("Contrast outline", isOn: $settings.contrastOutline)
                Toggle("Panel shadow", isOn: $settings.panelShadow)
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
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            hasPhysicalNotch = Self.detectPhysicalNotch()
        }
    }

    private var simulatedNotchBinding: Binding<Bool> {
        Binding(
            get: {
                SimulatedNotchPolicy.isEnabled(
                    force: settings.forceSimulatedNotch,
                    hasPhysicalNotch: hasPhysicalNotch
                )
            },
            set: { settings.forceSimulatedNotch = $0 }
        )
    }

    private var simulatedNotchExplanation: String {
        if !hasPhysicalNotch {
            return L10n.string(
                "Enabled automatically because no physical notch was detected."
            )
        }
        return settings.forceSimulatedNotch
            ? L10n.string("Also show MNotch on displays without a physical notch.")
            : L10n.string("Using the MacBook's physical notch.")
    }

    private static func detectPhysicalNotch() -> Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }
}

private struct AccessibilityPermissionRow: View {
    private let permission = AppServices.shared.accessibility

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "accessibility")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(permission.isGranted ? Color.green : .orange)
                    .frame(width: 24, height: 24)
                    .background(
                        (permission.isGranted ? Color.green : .orange).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibility")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Permission not granted")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Grant Access…") {
                    permission.requestAccess()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }
            Text("Required for MNotch to handle volume, brightness, and keyboard-backlight keys without also showing Apple's OSD. Other features keep working without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
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
                if settings.focusEnabled, !AppServices.shared.focus.available {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Needs Full Disk Access to read Focus state.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open Privacy Settings") {
                            SystemSettings.open(.fullDiskAccess)
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

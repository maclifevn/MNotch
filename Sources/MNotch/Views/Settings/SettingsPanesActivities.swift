import AppKit
import SwiftUI

struct NowPlayingPane: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.mediaEnabled) {
                    Label("Now Playing", systemImage: "play.fill")
                }
                SliderRow(
                    title: "Idle duration",
                    value: $settings.mediaIdleDuration,
                    range: 1...10,
                    step: 1
                ) { "\(Int($0)) s" }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Artwork badge").font(.callout)
                    IconCardPicker(
                        selection: $settings.mediaBadge,
                        options: MediaBadgeStyle.allCases,
                        label: { $0 == .none ? "None" : "App icon" },
                        symbol: { $0 == .none ? "nosign" : "app.badge.fill" }
                    )
                    Text("Alcove's Explicit/Format badges need metadata MediaRemote doesn't expose; the source app icon is shown instead.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                OptionCardPicker(
                    selection: $settings.mediaWaveformStyle,
                    options: WaveformStyle.allCases,
                    label: { style in
                        switch style {
                        case .monochrome: "Monochrome"
                        case .colored: "Colored"
                        case .gradient: "Gradient"
                        }
                    }
                ) { style in
                    WaveformPreview(style: style)
                }

                UnavailableRow(
                    title: "Use live waveform",
                    note: "Needs system-audio capture; not available."
                )
                Toggle("Disable compact waveform", isOn: $settings.mediaDisableCompactWaveform)
                Toggle("Disable artwork flip", isOn: $settings.mediaDisableArtworkFlip)
                Toggle("Hide while source app is active", isOn: $settings.mediaHideWhileSourceActive)
                Toggle("Hide media title extras", isOn: $settings.mediaHideTitleExtras)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Quick action").font(.callout)
                    IconCardPicker(
                        selection: $settings.mediaQuickAction,
                        options: MediaQuickAction.allCases,
                        label: { action in
                            switch action {
                            case .favorite: "Favorite"
                            case .shuffle: "Shuffle"
                            case .repeatMode: "Repeat"
                            case .copy: "Copy"
                            }
                        },
                        symbol: { action in
                            switch action {
                            case .favorite: "star.fill"
                            case .shuffle: "shuffle"
                            case .repeatMode: "repeat"
                            case .copy: "link"
                            }
                        }
                    )
                }
            }

            if !settings.mediaKnownSources.isEmpty {
                Section("Source") {
                    ForEach(settings.mediaKnownSources, id: \.self) { bundleID in
                        Toggle(isOn: Binding(
                            get: { settings.isSourceEnabled(bundleID) },
                            set: { enabled in
                                if enabled {
                                    settings.mediaDisabledSources.removeAll { $0 == bundleID }
                                } else {
                                    settings.mediaDisabledSources.append(bundleID)
                                }
                            }
                        )) {
                            SourceLabel(bundleID: bundleID)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SourceLabel: View {
    let bundleID: String

    var body: some View {
        HStack(spacing: 6) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: ""))
            } else {
                Text(bundleID)
            }
        }
    }
}

struct WaveformPreview: View {
    let style: WaveformStyle

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4) { i in
                Capsule()
                    .fill(color(index: i))
                    .frame(width: 4, height: [10, 16, 12, 18][i])
            }
        }
    }

    private func color(index: Int) -> Color {
        switch style {
        case .monochrome: .white.opacity(0.9)
        case .colored: .teal
        case .gradient: [Color.teal, .mint, .cyan, .white][index]
        }
    }
}

struct CalendarPane: View {
    @Bindable var settings = SettingsStore.shared
    private let calendar = AppServices.shared.calendar

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.calendarEnabled) {
                    Label("Calendar", systemImage: "calendar.badge.checkmark")
                }
                SliderRow(
                    title: "Time before event",
                    value: $settings.calendarTimeBefore,
                    range: 5...60,
                    step: 5
                ) { "\(Int($0)) m" }
                SoundToggleRow(
                    title: "Play sound on calendar event",
                    isOn: $settings.calendarSoundOnEvent,
                    effect: .event
                )
                SoundToggleRow(
                    title: "Play hourly chime",
                    isOn: $settings.calendarHourlyChime,
                    effect: .chime
                )
                Toggle("Use calendar color", isOn: $settings.calendarUseColor)
                Toggle("Disable activity during events", isOn: $settings.calendarDisableDuringEvents)
                UnavailableRow(
                    title: "Show weather on empty day",
                    note: "Weather integration isn't available."
                )
                Toggle("Use event indicators", isOn: $settings.calendarEventIndicators)
                Toggle("Always show month view", isOn: $settings.calendarMonthView)
            }
            Section {
                UnavailableRow(
                    title: "Notify when time to leave",
                    note: "Needs routing data; not available."
                )
            }
            Section("Calendars") {
                if calendar.calendars.isEmpty {
                    Text("Open the calendar tab once to grant access.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(calendar.calendars) { info in
                        CalendarRow(info: info)
                    }
                }
            }
            Section("Extension") {
                Toggle(isOn: $settings.calendarQuickPeek) {
                    Label("Quick Peek", systemImage: "eyeglasses")
                }
                Toggle("Before event starts", isOn: $settings.calendarPeekBeforeStart)
                Toggle("When event is starting", isOn: $settings.calendarPeekWhenStarting)
                SliderRow(
                    title: "Peek duration",
                    value: $settings.calendarPeekDuration,
                    range: 2...10,
                    step: 1
                ) { "\(Int($0)) s" }
                Toggle("Use colored calendar indicator", isOn: $settings.calendarColoredIndicator)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            calendar.ensureStarted()
        }
    }
}

struct CalendarRow: View {
    let info: CalendarService.CalendarInfo
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { !settings.calendarDisabledCalendars.contains(info.id) },
                set: { enabled in
                    if enabled {
                        settings.calendarDisabledCalendars.removeAll { $0 == info.id }
                    } else {
                        settings.calendarDisabledCalendars.append(info.id)
                    }
                }
            )) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: info.red, green: info.green, blue: info.blue))
                        .frame(width: 10, height: 10)
                    Text(info.title)
                }
            }
            Spacer()
            Picker("", selection: Binding(
                get: { settings.use(for: info.id) },
                set: { settings.calendarUses[info.id] = $0.rawValue }
            )) {
                Text("Both").tag(CalendarUse.both)
                Text("Notifications").tag(CalendarUse.notifications)
                Text("Activity").tag(CalendarUse.activity)
            }
            .labelsHidden()
            .frame(width: 130)
        }
    }
}

struct FileTrayPane: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.shelfEnabled) {
                    Label("File Tray", systemImage: "tray.fill")
                }
                Text("Drop files onto the notch to collect them; drag out to reuse, AirDrop from the tray tab.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

struct LockScreenPane: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.lockEnabled) {
                    Label("Lock Screen", systemImage: "lock.fill")
                }
                SliderRow(
                    title: "Keep awake",
                    value: $settings.lockKeepAwake,
                    range: 0...60,
                    step: 5
                ) { "\(Int($0)) m" }
                Toggle("Show on screen saver", isOn: $settings.lockShowOnScreenSaver)
                SoundToggleRow(
                    title: "Play sound on lock",
                    isOn: $settings.lockSoundOnLock,
                    effect: .lock
                )
                SoundToggleRow(
                    title: "Play sound on unlock",
                    isOn: $settings.lockSoundOnUnlock,
                    effect: .unlock
                )
            }

            Section("Widgets") {
                Toggle(isOn: $settings.lockWidgetBattery) {
                    Label("Battery", systemImage: "bolt.fill")
                }
                Toggle(isOn: $settings.lockWidgetConnectivity) {
                    Label("Connectivity", systemImage: "headphones")
                }
                Toggle(isOn: $settings.lockWidgetFocus) {
                    Label("Focus", systemImage: "moon.fill")
                }
                Toggle(isOn: $settings.lockWidgetCalendar) {
                    Label("Calendar", systemImage: "calendar")
                }
            }

            Section {
                Toggle(isOn: $settings.lockNowPlaying) {
                    Label("Now Playing", systemImage: "play.fill")
                }
                OptionCardPicker(
                    selection: $settings.lockNowPlayingStyle,
                    options: LockCardStyle.allCases,
                    label: { style in
                        switch style {
                        case .glass: "Glass"
                        case .clear: "Clear"
                        case .frosted: "Frosted"
                        }
                    }
                ) { style in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.blue.opacity(style == .clear ? 0.25 : 0.5))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 11)
                        .background(.blue.opacity(style == .frosted ? 0.35 : 0.12))
                }
                SliderRow(
                    title: "Idle duration",
                    value: $settings.lockIdleDuration,
                    range: 1...30,
                    step: 1
                ) { "\(Int($0)) m" }
                Toggle("Show volume control", isOn: $settings.lockShowVolume)
                SliderRow(
                    title: "Offset tuning",
                    value: $settings.lockOffset,
                    range: -200...200,
                    step: 10
                ) { "\(Int($0)) px" }
            }

            Section {
                UnavailableRow(
                    title: "Weather",
                    note: "Needs a weather data source; not available."
                )
            }

            Section("Allowed Notifications") {
                Toggle(isOn: $settings.lockAllowBattery) {
                    Label("Battery", systemImage: "bolt.fill")
                }
                Toggle(isOn: $settings.lockAllowConnectivity) {
                    Label("Connectivity", systemImage: "headphones")
                }
                Toggle(isOn: $settings.lockAllowFocus) {
                    Label("Focus", systemImage: "moon.fill")
                }
                Toggle(isOn: $settings.lockAllowDisplay) {
                    Label("Display", systemImage: "sun.max.fill")
                }
                Toggle(isOn: $settings.lockAllowSound) {
                    Label("Sound", systemImage: "speaker.wave.2.fill")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                }
                LabeledContent("Build") {
                    Text("SwiftPM, no Xcode")
                }
            }
            Section("Credits") {
                Text("Now-playing relay: mediaremote-adapter by Jonas van den Berg (BSD-3-Clause), built from vendored source.")
                    .font(.caption)
                Text("Inspired by Alcove (tryalcove.com). MNotch is a personal, non-commercial clone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

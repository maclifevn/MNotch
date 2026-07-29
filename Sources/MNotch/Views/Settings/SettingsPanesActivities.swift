import AppKit
import EventKit
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

                let players = MediaRemoteService.installedPlayers
                if !players.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Play button starts", selection: $settings.mediaPreferredPlayer) {
                            Text("System default").tag("")
                            ForEach(players) { player in
                                Text(player.name).tag(player.bundleID)
                            }
                        }
                        Text("Which app the notch's Play button opens when nothing is loaded yet. macOS still controls whatever is already playing — press Play there once and the notch follows it.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

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
            if let icon = ApplicationIconCache.shared.icon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(ApplicationIconCache.shared.displayName(for: bundleID))
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
                Toggle("Use event indicators", isOn: $settings.calendarEventIndicators)
                Toggle("Always show month view", isOn: $settings.calendarMonthView)
                Picker("Upcoming events", selection: $settings.calendarUpcomingScope) {
                    Text("Today only").tag("off")
                    Text("Next week").tag("week")
                    Text("Next month").tag("month")
                }
            }
            Section("Calendars") {
                if calendar.calendars.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MNotch needs access to your calendars.")
                            .foregroundStyle(.secondary)
                        Button("Grant Access") { calendar.requestAccess() }
                            .controlSize(.small)
                    }
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
            // Populate an already-authorized account without ever triggering a
            // permission prompt merely because Settings was opened.
            if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
                calendar.ensureStarted()
            }
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

struct PomodoroPane: View {
    @Bindable var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.pomodoroEnabled) {
                    Label("Pomodoro", systemImage: "timer")
                }
                .onChange(of: settings.pomodoroEnabled) { _, on in
                    // Turning the feature off must not leave a session ticking
                    // (its wing would linger with no tab to manage it).
                    if !on { AppServices.shared.pomodoro.reset() }
                }
                Text("A focus timer in the notch: the countdown lives beside the camera while a session runs, and the notch nudges you when it's time for a break.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                SliderRow(
                    title: "Focus length",
                    value: $settings.pomodoroWorkMinutes,
                    range: 10...60,
                    step: 5
                ) { "\(Int($0)) m" }
                SliderRow(
                    title: "Short break",
                    value: $settings.pomodoroShortBreakMinutes,
                    range: 3...15,
                    step: 1
                ) { "\(Int($0)) m" }
                SliderRow(
                    title: "Long break",
                    value: $settings.pomodoroLongBreakMinutes,
                    range: 10...30,
                    step: 5
                ) { "\(Int($0)) m" }
                SliderRow(
                    title: "Sessions before long break",
                    value: $settings.pomodoroCyclesPerLongBreak,
                    range: 2...6,
                    step: 1
                ) { "\(Int($0))" }
                Toggle("Play sound on phase change", isOn: $settings.pomodoroSound)
                Toggle("Start next phase automatically", isOn: $settings.pomodoroAutoContinue)
            }
        }
        .formStyle(.grouped)
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
                Toggle(
                    "Clear successfully dragged files",
                    isOn: $settings.shelfClearAfterDrag
                )
                .disabled(!settings.shelfEnabled)
                Text("Drop files onto the notch, select one or many, then Quick Look, open, reveal in Finder, drag out, or AirDrop them.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("When enabled, a successful drop removes only the dragged files from the tray. MNotch retains an invisible backing copy for 24 hours so apps such as browsers can finish importing or uploading it safely.")
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
                        case .clear: "Transparent"
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
                VStack(spacing: 11) {
                    if let logo = Self.bundledImage("icon_mnotch") {
                        logo.resizable().interpolation(.high)
                            .frame(width: 78, height: 78)
                            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                    }
                    VStack(spacing: 3) {
                        Text("MNotch").font(.system(size: 20, weight: .bold))
                        Text("A Dynamic Island for your Mac")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Self.versionString)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            // MNotch has no Dock icon, so quitting isn't obvious. Spell out
            // every exit here — this is the pane people open looking for them.
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quit MNotch").font(.callout)
                        Text("Also ⌘Q, or the menu bar icon.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }

            Section("Ủng hộ") {
                HStack(alignment: .top, spacing: 14) {
                    if let qr = Self.bundledImage("donate-qr") {
                        qr.resizable().interpolation(.high)
                            .frame(width: 106, height: 106)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                            )
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mời mình ly cà phê ☕").font(.system(size: 14, weight: .semibold))
                        Text("Nếu MNotch hữu ích với bạn, một ly cà phê nhỏ giúp mình duy trì và phát triển dự án. Cảm ơn bạn! 🙏")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Quét bằng MoMo hoặc app ngân hàng (VietQR · Napas 247)")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                HStack(spacing: 0) {
                    Text("Made with ❤️ for ").foregroundStyle(.secondary)
                    Link(
                        "Maclife & Đồng Bọn",
                        destination: URL(string: "https://www.facebook.com/groups/maclife.vn")!
                    )
                }
                .font(.callout)
                .frame(maxWidth: .infinity)
            }

            Section {
                Text("mediaremote-adapter · BSD-3-Clause · Jonas van den Berg")
                    .font(.caption2).foregroundStyle(.tertiary)
                DisclosureGroup("Licenses") {
                    Text(Self.mediaRemoteAdapterLicense)
                        .font(.system(size: 9.5).monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return String(
            format: L10n.string("Version %@ (%@) · SwiftPM"),
            v,
            b
        )
    }

    private static func bundledImage(_ name: String) -> Image? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: image)
    }

    /// Reproduced per the BSD 3-Clause requirement that binary distributions
    /// include the copyright notice, conditions, and disclaimer.
    private static let mediaRemoteAdapterLicense = """
    BSD 3-Clause License

    Copyright (c) 2025, Jonas van den Berg and contributors

    Redistribution and use in source and binary forms, with or without \
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, \
    this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice, \
    this list of conditions and the following disclaimer in the documentation \
    and/or other materials provided with the distribution.

    3. Neither the name of the copyright holder nor the names of its contributors \
    may be used to endorse or promote products derived from this software without \
    specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" \
    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE \
    ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE \
    LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR \
    CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF \
    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS \
    INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN \
    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) \
    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE \
    POSSIBILITY OF SUCH DAMAGE.
    """
}

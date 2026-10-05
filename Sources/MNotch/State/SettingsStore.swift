import Observation
import ServiceManagement

enum SimulatedNotchPolicy {
    /// A user may force simulation on non-notched displays. When no physical
    /// notch is available, simulation is mandatory so the app stays reachable.
    static func isEnabled(force: Bool, hasPhysicalNotch: Bool) -> Bool {
        force || !hasPhysicalNotch
    }
}

/// UserDefaults-backed settings, one property per Alcove-style toggle.
/// Every stored property persists via its didSet; defaults mirror Alcove's.
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    @ObservationIgnored private let d: UserDefaults
    @ObservationIgnored private var loading = true

    /// Set by NotchWindowController to rebuild panels on display-ish toggles.
    @ObservationIgnored var onDisplayConfigChanged: (() -> Void)?

    private func save(_ key: String, _ value: Any) {
        guard !loading else { return }
        d.set(value, forKey: key)
    }

    // MARK: General

    var launchAtLogin: Bool { didSet { applyLaunchAtLogin() } }
    var appLanguage: AppLanguage {
        didSet {
            save(AppLanguage.preferenceKey, appLanguage.rawValue)
            guard !loading else { return }
            AppLanguage.applyOverride(appLanguage)
            languageRestartRequired = AppLanguageRestartPolicy.requiresRestart(
                selected: appLanguage,
                launched: languageAtLaunch
            )
        }
    }
    private(set) var languageRestartRequired = false
    @ObservationIgnored private var languageAtLaunch: AppLanguage = .system
    /// Set once the first-launch Welcome window has been dismissed.
    var hasSeenWelcome: Bool { didSet { save("general.seenWelcome", hasSeenWelcome) } }
    var hideInFullscreen: Bool { didSet { save("general.hideFullscreen", hideInFullscreen) } }
    var hideInMissionControl: Bool { didSet { save("general.hideMissionControl", hideInMissionControl) } }
    var hideWhileGaming: Bool { didSet { save("general.hideGaming", hideWhileGaming) } }
    var hideFromScreenCapture: Bool {
        didSet {
            save("general.hideCapture", hideFromScreenCapture)
            onDisplayConfigChanged?()
        }
    }
    var forceSimulatedNotch: Bool {
        didSet {
            save("general.forceNotch", forceSimulatedNotch)
            onDisplayConfigChanged?()
        }
    }
    var hideMenuBarIcon: Bool { didSet { save("general.hideMenuBar", hideMenuBarIcon) } }
    /// "all" | "main" | "builtIn" | display id string
    var displayTarget: String {
        didSet {
            save("general.displayTarget", displayTarget)
            onDisplayConfigChanged?()
        }
    }

    var idleActivity: IdleActivity { didSet { save("general.idleActivity", idleActivity.rawValue) } }
    var idleMostRecent: Bool { didSet { save("general.idleMostRecent", idleMostRecent) } }

    var contrastOutline: Bool { didSet { save("general.contrastOutline", contrastOutline) } }
    /// Dark, wallpaper-independent shadow under full notch panels. The stored
    /// key keeps its legacy name so existing preferences migrate implicitly.
    var panelShadow: Bool { didSet { save("general.progressiveBlur", panelShadow) } }
    var hapticFeedback: Bool { didSet { save("general.haptic", hapticFeedback) } }
    var expandOnHover: Bool { didSet { save("general.expandOnHover", expandOnHover) } }

    var gestureNatural: Bool { didSet { save("gesture.natural", gestureNatural) } }
    var gestureToggleOpen: Bool { didSet { save("gesture.toggleOpen", gestureToggleOpen) } }
    var gestureCycleActivity: Bool { didSet { save("gesture.cycle", gestureCycleActivity) } }
    var gestureDismissActivity: Bool { didSet { save("gesture.dismiss", gestureDismissActivity) } }
    var gestureSkipMedia: Bool { didSet { save("gesture.skipMedia", gestureSkipMedia) } }

    private var storedNotchWidthOffset: Double
    var notchWidthOffset: Double {
        get { storedNotchWidthOffset }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "tuning.width", fallback: 0)
            storedNotchWidthOffset = value
            save("tuning.width", value)
            onDisplayConfigChanged?()
        }
    }
    private var storedNotchHeightOffset: Double
    var notchHeightOffset: Double {
        get { storedNotchHeightOffset }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "tuning.height", fallback: 0)
            storedNotchHeightOffset = value
            save("tuning.height", value)
            onDisplayConfigChanged?()
        }
    }

    // MARK: Battery

    var batteryEnabled: Bool { didSet { save("battery.enabled", batteryEnabled) } }
    private var storedBatteryDuration: Double
    var batteryDuration: Double {
        get { storedBatteryDuration }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "battery.duration", fallback: 0)
            storedBatteryDuration = value
            save("battery.duration", value)
        }
    }
    var batteryNotifyLowPower: Bool { didSet { save("battery.lowPower", batteryNotifyLowPower) } }
    var batteryWarnLow: Bool { didSet { save("battery.warnLow", batteryWarnLow) } }
    private var storedBatteryLowThreshold: Double
    var batteryLowThreshold: Double {
        get { storedBatteryLowThreshold }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "battery.threshold", fallback: 0)
            storedBatteryLowThreshold = value
            save("battery.threshold", value)
        }
    }
    var batterySoundOnLow: Bool { didSet { save("battery.sound", batterySoundOnLow) } }
    var batteryHideLabel: Bool { didSet { save("battery.hideLabel", batteryHideLabel) } }
    var batteryHidePercentage: Bool { didSet { save("battery.hidePct", batteryHidePercentage) } }

    // MARK: Connectivity

    var connectivityEnabled: Bool { didSet { save("bt.enabled", connectivityEnabled) } }
    private var storedConnectivityDuration: Double
    var connectivityDuration: Double {
        get { storedConnectivityDuration }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "bt.duration", fallback: 0)
            storedConnectivityDuration = value
            save("bt.duration", value)
        }
    }
    var connectivityWarnLow: Bool { didSet { save("bt.warnLow", connectivityWarnLow) } }
    private var storedConnectivityLowThreshold: Double
    var connectivityLowThreshold: Double {
        get { storedConnectivityLowThreshold }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "bt.threshold", fallback: 0)
            storedConnectivityLowThreshold = value
            save("bt.threshold", value)
        }
    }
    var connectivitySoundOnLow: Bool { didSet { save("bt.sound", connectivitySoundOnLow) } }

    // MARK: Focus

    var focusEnabled: Bool { didSet { save("focus.enabled", focusEnabled) } }
    private var storedFocusDuration: Double
    var focusDuration: Double {
        get { storedFocusDuration }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "focus.duration", fallback: 0)
            storedFocusDuration = value
            save("focus.duration", value)
        }
    }
    var focusSoundOnSleep: Bool { didSet { save("focus.sleepSound", focusSoundOnSleep) } }
    var focusReplaceWaveform: Bool { didSet { save("focus.replaceWaveform", focusReplaceWaveform) } }
    var focusHideLabel: Bool { didSet { save("focus.hideLabel", focusHideLabel) } }
    var focusAllowBattery: Bool { didSet { save("focus.allowBattery", focusAllowBattery) } }
    var focusAllowConnectivity: Bool { didSet { save("focus.allowBt", focusAllowConnectivity) } }
    var focusAllowDisplay: Bool { didSet { save("focus.allowDisplay", focusAllowDisplay) } }
    var focusAllowSound: Bool { didSet { save("focus.allowSound", focusAllowSound) } }

    // MARK: Pomodoro

    var pomodoroEnabled: Bool { didSet { save("pomo.enabled", pomodoroEnabled) } }
    private var storedPomodoroWorkMinutes: Double
    var pomodoroWorkMinutes: Double {
        get { storedPomodoroWorkMinutes }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "pomo.work", fallback: 0)
            storedPomodoroWorkMinutes = value
            save("pomo.work", value)
        }
    }
    private var storedPomodoroShortBreakMinutes: Double
    var pomodoroShortBreakMinutes: Double {
        get { storedPomodoroShortBreakMinutes }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "pomo.shortBreak", fallback: 0)
            storedPomodoroShortBreakMinutes = value
            save("pomo.shortBreak", value)
        }
    }
    private var storedPomodoroLongBreakMinutes: Double
    var pomodoroLongBreakMinutes: Double {
        get { storedPomodoroLongBreakMinutes }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "pomo.longBreak", fallback: 0)
            storedPomodoroLongBreakMinutes = value
            save("pomo.longBreak", value)
        }
    }
    private var storedPomodoroCyclesPerLongBreak: Double
    var pomodoroCyclesPerLongBreak: Double {
        get { storedPomodoroCyclesPerLongBreak }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "pomo.cycles", fallback: 0)
            storedPomodoroCyclesPerLongBreak = value
            save("pomo.cycles", value)
        }
    }
    var pomodoroSound: Bool { didSet { save("pomo.sound", pomodoroSound) } }
    var pomodoroAutoContinue: Bool { didSet { save("pomo.autoContinue", pomodoroAutoContinue) } }

    // MARK: Display HUD (brightness)

    var displayHUDEnabled: Bool { didSet { save("display.enabled", displayHUDEnabled) } }
    private var storedDisplayHUDDuration: Double
    var displayHUDDuration: Double {
        get { storedDisplayHUDDuration }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "display.duration", fallback: 0)
            storedDisplayHUDDuration = value
            save("display.duration", value)
        }
    }
    var displayBarStyle: HUDBarStyle { didSet { save("display.barStyle", displayBarStyle.rawValue) } }
    var displayShowPercentage: Bool { didSet { save("display.showPct", displayShowPercentage) } }
    var displayHideLabel: Bool { didSet { save("display.hideLabel", displayHideLabel) } }
    var displayAnimSpeed: AnimSpeed { didSet { save("display.animSpeed", displayAnimSpeed.rawValue) } }

    // MARK: Sound HUD (volume)

    var soundHUDEnabled: Bool { didSet { save("sound.enabled", soundHUDEnabled) } }
    private var storedSoundHUDDuration: Double
    var soundHUDDuration: Double {
        get { storedSoundHUDDuration }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "sound.duration", fallback: 0)
            storedSoundHUDDuration = value
            save("sound.duration", value)
        }
    }
    var soundBarStyle: HUDBarStyle { didSet { save("sound.barStyle", soundBarStyle.rawValue) } }
    var soundShowPercentage: Bool { didSet { save("sound.showPct", soundShowPercentage) } }
    var soundHideLabel: Bool { didSet { save("sound.hideLabel", soundHideLabel) } }
    var soundAnimSpeed: AnimSpeed { didSet { save("sound.animSpeed", soundAnimSpeed.rawValue) } }
    var soundIconStyle: SoundIconStyle { didSet { save("sound.iconStyle", soundIconStyle.rawValue) } }

    // MARK: Now Playing

    var mediaEnabled: Bool { didSet { save("media.enabled", mediaEnabled) } }
    private var storedMediaIdleDuration: Double
    var mediaIdleDuration: Double {
        get { storedMediaIdleDuration }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "media.idleDuration", fallback: 0)
            storedMediaIdleDuration = value
            save("media.idleDuration", value)
        }
    }
    var mediaBadge: MediaBadgeStyle { didSet { save("media.badge", mediaBadge.rawValue) } }
    var mediaWaveformStyle: WaveformStyle { didSet { save("media.waveform", mediaWaveformStyle.rawValue) } }
    var mediaDisableCompactWaveform: Bool { didSet { save("media.noCompactWave", mediaDisableCompactWaveform) } }
    var mediaDisableArtworkFlip: Bool { didSet { save("media.noFlip", mediaDisableArtworkFlip) } }
    var mediaHideWhileSourceActive: Bool { didSet { save("media.hideSourceActive", mediaHideWhileSourceActive) } }
    var mediaHideTitleExtras: Bool { didSet { save("media.hideExtras", mediaHideTitleExtras) } }
    var mediaQuickAction: MediaQuickAction { didSet { save("media.quickAction", mediaQuickAction.rawValue) } }
    var mediaKnownSources: [String] { didSet { save("media.knownSources", mediaKnownSources) } }
    var mediaDisabledSources: [String] { didSet { save("media.disabledSources", mediaDisabledSources) } }
    /// Bundle id of the app the notch's Play button starts when nothing is
    /// already loaded from it ("" = let macOS pick, its usual default).
    var mediaPreferredPlayer: String { didSet { save("media.preferredPlayer", mediaPreferredPlayer) } }

    // MARK: Calendar

    var calendarEnabled: Bool { didSet { save("cal.enabled", calendarEnabled) } }
    private var storedCalendarTimeBefore: Double
    var calendarTimeBefore: Double {
        get { storedCalendarTimeBefore }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "cal.timeBefore", fallback: 0)
            storedCalendarTimeBefore = value
            save("cal.timeBefore", value)
        }
    }
    var calendarSoundOnEvent: Bool { didSet { save("cal.eventSound", calendarSoundOnEvent) } }
    var calendarHourlyChime: Bool { didSet { save("cal.chime", calendarHourlyChime) } }
    var calendarUseColor: Bool { didSet { save("cal.useColor", calendarUseColor) } }
    var calendarDisableDuringEvents: Bool { didSet { save("cal.noDuringEvents", calendarDisableDuringEvents) } }
    var calendarEventIndicators: Bool { didSet { save("cal.indicators", calendarEventIndicators) } }
    var calendarMonthView: Bool { didSet { save("cal.monthView", calendarMonthView) } }
    /// How far ahead the tab lists events: "off" (today only) | "week" | "month".
    var calendarUpcomingScope: String { didSet { save("cal.upcomingScope", calendarUpcomingScope) } }
    var calendarQuickPeek: Bool { didSet { save("cal.peek", calendarQuickPeek) } }
    var calendarPeekBeforeStart: Bool { didSet { save("cal.peekBefore", calendarPeekBeforeStart) } }
    var calendarPeekWhenStarting: Bool { didSet { save("cal.peekStarting", calendarPeekWhenStarting) } }
    private var storedCalendarPeekDuration: Double
    var calendarPeekDuration: Double {
        get { storedCalendarPeekDuration }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "cal.peekDuration", fallback: 0)
            storedCalendarPeekDuration = value
            save("cal.peekDuration", value)
        }
    }
    var calendarColoredIndicator: Bool { didSet { save("cal.coloredIndicator", calendarColoredIndicator) } }
    var calendarDisabledCalendars: [String] { didSet { save("cal.disabled", calendarDisabledCalendars) } }
    /// calendarIdentifier -> CalendarUse rawValue (default both)
    var calendarUses: [String: String] { didSet { save("cal.uses", calendarUses) } }

    // MARK: Shelf & Lock Screen

    var shelfEnabled: Bool { didSet { save("shelf.enabled", shelfEnabled) } }
    var shelfClearAfterDrag: Bool {
        didSet { save("shelf.clearAfterDrag", shelfClearAfterDrag) }
    }

    var lockSoundOnLock: Bool { didSet { save("lock.soundLock", lockSoundOnLock) } }
    var lockSoundOnUnlock: Bool { didSet { save("lock.soundUnlock", lockSoundOnUnlock) } }
    private var storedLockKeepAwake: Double
    var lockKeepAwake: Double {
        get { storedLockKeepAwake }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "lock.keepAwake", fallback: 0)
            storedLockKeepAwake = value
            save("lock.keepAwake", value)
        }
    }
    var lockEnabled: Bool { didSet { save("lock.enabled", lockEnabled) } }
    var lockShowOnScreenSaver: Bool { didSet { save("lock.screensaver", lockShowOnScreenSaver) } }
    var lockWidgetBattery: Bool { didSet { save("lock.widget.battery", lockWidgetBattery) } }
    var lockWidgetConnectivity: Bool { didSet { save("lock.widget.connectivity", lockWidgetConnectivity) } }
    var lockWidgetFocus: Bool { didSet { save("lock.widget.focus", lockWidgetFocus) } }
    var lockWidgetCalendar: Bool { didSet { save("lock.widget.calendar", lockWidgetCalendar) } }
    var lockNowPlaying: Bool { didSet { save("lock.nowPlaying", lockNowPlaying) } }
    var lockNowPlayingStyle: LockCardStyle { didSet { save("lock.npStyle", lockNowPlayingStyle.rawValue) } }
    private var storedLockIdleDuration: Double
    var lockIdleDuration: Double {
        get { storedLockIdleDuration }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "lock.idle", fallback: 0)
            storedLockIdleDuration = value
            save("lock.idle", value)
        }
    }
    var lockShowVolume: Bool { didSet { save("lock.volume", lockShowVolume) } }
    private var storedLockOffset: Double
    var lockOffset: Double {
        get { storedLockOffset }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "lock.offset", fallback: 0)
            storedLockOffset = value
            save("lock.offset", value)
        }
    }
    var lockAllowBattery: Bool { didSet { save("lock.allow.battery", lockAllowBattery) } }
    var lockAllowConnectivity: Bool { didSet { save("lock.allow.connectivity", lockAllowConnectivity) } }
    var lockAllowFocus: Bool { didSet { save("lock.allow.focus", lockAllowFocus) } }
    var lockAllowDisplay: Bool { didSet { save("lock.allow.display", lockAllowDisplay) } }
    var lockAllowSound: Bool { didSet { save("lock.allow.sound", lockAllowSound) } }

    // Agent monitor
    var agentEnabled: Bool { didSet { save("agent.enabled", agentEnabled) } }
    var agentSound: Bool { didSet { save("agent.sound", agentSound) } }
    private var storedAgentDuration: Double
    var agentDuration: Double {
        get { storedAgentDuration }
        set {
            let value = PreferenceNumberPolicy.value(newValue, key: "agent.duration", fallback: 0)
            storedAgentDuration = value
            save("agent.duration", value)
        }
    }
    var agentAutoExpand: Bool { didSet { save("agent.autoExpand", agentAutoExpand) } }
    var agentDeferToTerminal: Bool { didSet { save("agent.deferToTerminal", agentDeferToTerminal) } }

    // MARK: - Init / load

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        // Local shadow so the nested helpers don't touch self before
        // initialization completes.
        let d = defaults
        func flag(_ key: String, _ fallback: Bool, legacy: String? = nil) -> Bool {
            if d.object(forKey: key) != nil { return d.bool(forKey: key) }
            if let legacy, d.object(forKey: legacy) != nil { return d.bool(forKey: legacy) }
            return fallback
        }
        func num(_ key: String, _ fallback: Double) -> Double {
            PreferenceNumberPolicy.value(d.object(forKey: key), key: key, fallback: fallback)
        }
        func str(_ key: String, _ fallback: String) -> String {
            d.string(forKey: key) ?? fallback
        }
        func opt<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            guard let raw = d.string(forKey: key), let value = T(rawValue: raw) else {
                return fallback
            }
            return value
        }

        launchAtLogin = SMAppService.mainApp.status == .enabled
        let initialLanguage = AppLanguage.resolvedPreference(
            from: d.string(forKey: AppLanguage.preferenceKey)
        )
        appLanguage = initialLanguage
        languageAtLaunch = initialLanguage
        hasSeenWelcome = flag("general.seenWelcome", false)
        hideInFullscreen = flag("general.hideFullscreen", true)
        hideInMissionControl = flag("general.hideMissionControl", true)
        hideWhileGaming = flag("general.hideGaming", false)
        hideFromScreenCapture = flag("general.hideCapture", false)
        // This stores only the user's override. The effective state also
        // includes the automatic no-physical-notch fallback; keeping those
        // separate lets Settings follow display changes without accidentally
        // persisting a temporary clamshell state.
        forceSimulatedNotch = flag("general.forceNotch", false, legacy: "display.fakeNotch")
        hideMenuBarIcon = flag("general.hideMenuBar", false)
        displayTarget = str("general.displayTarget", "all")
        idleActivity = opt("general.idleActivity", IdleActivity.playing)
        idleMostRecent = flag("general.idleMostRecent", false)
        contrastOutline = flag("general.contrastOutline", true)
        panelShadow = flag("general.progressiveBlur", true)
        hapticFeedback = flag("general.haptic", true)
        expandOnHover = flag("general.expandOnHover", false)
        gestureNatural = flag("gesture.natural", false)
        gestureToggleOpen = flag("gesture.toggleOpen", true)
        gestureCycleActivity = flag("gesture.cycle", true)
        gestureDismissActivity = flag("gesture.dismiss", true)
        gestureSkipMedia = flag("gesture.skipMedia", true)
        storedNotchWidthOffset = num("tuning.width", 0)
        storedNotchHeightOffset = num("tuning.height", 0)

        batteryEnabled = flag("battery.enabled", true, legacy: "feature.battery")
        storedBatteryDuration = num("battery.duration", 5)
        batteryNotifyLowPower = flag("battery.lowPower", true)
        batteryWarnLow = flag("battery.warnLow", true)
        storedBatteryLowThreshold = num("battery.threshold", 10)
        batterySoundOnLow = flag("battery.sound", false)
        batteryHideLabel = flag("battery.hideLabel", false)
        batteryHidePercentage = flag("battery.hidePct", false)

        connectivityEnabled = flag("bt.enabled", true, legacy: "feature.bluetooth")
        storedConnectivityDuration = num("bt.duration", 5)
        connectivityWarnLow = flag("bt.warnLow", true)
        storedConnectivityLowThreshold = num("bt.threshold", 20)
        connectivitySoundOnLow = flag("bt.sound", false)

        // Focus reads a protected on-disk database every few seconds and is
        // unusable without Full Disk Access. Keep this optional integration
        // opt-in; an absent preference should not create background work.
        focusEnabled = flag("focus.enabled", false)
        storedFocusDuration = num("focus.duration", 5)
        focusSoundOnSleep = flag("focus.sleepSound", false)
        focusReplaceWaveform = flag("focus.replaceWaveform", false)
        focusHideLabel = flag("focus.hideLabel", false)
        focusAllowBattery = flag("focus.allowBattery", true)
        focusAllowConnectivity = flag("focus.allowBt", true)
        focusAllowDisplay = flag("focus.allowDisplay", true)
        focusAllowSound = flag("focus.allowSound", true)

        pomodoroEnabled = flag("pomo.enabled", true)
        storedPomodoroWorkMinutes = num("pomo.work", 25)
        storedPomodoroShortBreakMinutes = num("pomo.shortBreak", 5)
        storedPomodoroLongBreakMinutes = num("pomo.longBreak", 15)
        storedPomodoroCyclesPerLongBreak = num("pomo.cycles", 4)
        pomodoroSound = flag("pomo.sound", true)
        pomodoroAutoContinue = flag("pomo.autoContinue", true)

        displayHUDEnabled = flag("display.enabled", true, legacy: "feature.hud")
        storedDisplayHUDDuration = num("display.duration", 1.5)
        displayBarStyle = opt("display.barStyle", HUDBarStyle.white)
        displayShowPercentage = flag("display.showPct", false)
        displayHideLabel = flag("display.hideLabel", false)
        displayAnimSpeed = opt("display.animSpeed", AnimSpeed.fast)

        soundHUDEnabled = flag("sound.enabled", true, legacy: "feature.hud")
        storedSoundHUDDuration = num("sound.duration", 1.5)
        soundBarStyle = opt("sound.barStyle", HUDBarStyle.white)
        soundShowPercentage = flag("sound.showPct", false)
        soundHideLabel = flag("sound.hideLabel", false)
        soundAnimSpeed = opt("sound.animSpeed", AnimSpeed.fast)
        soundIconStyle = opt("sound.iconStyle", SoundIconStyle.device)

        mediaEnabled = flag("media.enabled", true, legacy: "feature.media")
        storedMediaIdleDuration = num("media.idleDuration", 3)
        mediaBadge = opt("media.badge", MediaBadgeStyle.none)
        mediaWaveformStyle = opt("media.waveform", WaveformStyle.colored)
        mediaDisableCompactWaveform = flag("media.noCompactWave", false)
        mediaDisableArtworkFlip = flag("media.noFlip", false)
        mediaHideWhileSourceActive = flag("media.hideSourceActive", false)
        mediaHideTitleExtras = flag("media.hideExtras", false)
        mediaQuickAction = opt("media.quickAction", MediaQuickAction.shuffle)
        mediaKnownSources = d.stringArray(forKey: "media.knownSources") ?? []
        mediaDisabledSources = d.stringArray(forKey: "media.disabledSources") ?? []
        mediaPreferredPlayer = str("media.preferredPlayer", "")

        calendarEnabled = flag("cal.enabled", true, legacy: "feature.calendar")
        storedCalendarTimeBefore = num("cal.timeBefore", 15)
        calendarSoundOnEvent = flag("cal.eventSound", false)
        calendarHourlyChime = flag("cal.chime", false)
        calendarUseColor = flag("cal.useColor", true)
        calendarDisableDuringEvents = flag("cal.noDuringEvents", false)
        calendarEventIndicators = flag("cal.indicators", false)
        calendarMonthView = flag("cal.monthView", true)
        calendarUpcomingScope = str("cal.upcomingScope", "week")
        calendarQuickPeek = flag("cal.peek", true)
        calendarPeekBeforeStart = flag("cal.peekBefore", false)
        calendarPeekWhenStarting = flag("cal.peekStarting", true)
        storedCalendarPeekDuration = num("cal.peekDuration", 4)
        calendarColoredIndicator = flag("cal.coloredIndicator", true)
        calendarDisabledCalendars = d.stringArray(forKey: "cal.disabled") ?? []
        calendarUses = (d.dictionary(forKey: "cal.uses") as? [String: String]) ?? [:]

        shelfEnabled = flag("shelf.enabled", true, legacy: "feature.shelf")
        shelfClearAfterDrag = flag("shelf.clearAfterDrag", false)
        lockSoundOnLock = flag("lock.soundLock", false)
        lockSoundOnUnlock = flag("lock.soundUnlock", false)
        storedLockKeepAwake = num("lock.keepAwake", 0)
        // Lock Screen relies on private WindowServer APIs. Keep the optional,
        // higher-risk feature opt-in; existing explicit preferences survive.
        lockEnabled = flag("lock.enabled", false)
        lockShowOnScreenSaver = flag("lock.screensaver", false)
        lockWidgetBattery = flag("lock.widget.battery", true)
        lockWidgetConnectivity = flag("lock.widget.connectivity", true)
        lockWidgetFocus = flag("lock.widget.focus", true)
        lockWidgetCalendar = flag("lock.widget.calendar", false)
        lockNowPlaying = flag("lock.nowPlaying", true)
        lockNowPlayingStyle = opt("lock.npStyle", LockCardStyle.glass)
        storedLockIdleDuration = num("lock.idle", 10)
        lockShowVolume = flag("lock.volume", false)
        storedLockOffset = num("lock.offset", 0)
        lockAllowBattery = flag("lock.allow.battery", true)
        lockAllowConnectivity = flag("lock.allow.connectivity", true)
        lockAllowFocus = flag("lock.allow.focus", true)
        lockAllowDisplay = flag("lock.allow.display", true)
        lockAllowSound = flag("lock.allow.sound", true)

        agentEnabled = flag("agent.enabled", false)
        agentSound = flag("agent.sound", true)
        storedAgentDuration = num("agent.duration", 4)
        agentAutoExpand = flag("agent.autoExpand", true)
        agentDeferToTerminal = flag("agent.deferToTerminal", true)

        loading = false
    }

    // MARK: - Helpers

    func use(for calendarID: String) -> CalendarUse {
        calendarUses[calendarID].flatMap(CalendarUse.init(rawValue:)) ?? .both
    }

    func isSourceEnabled(_ bundleID: String) -> Bool {
        !mediaDisabledSources.contains(bundleID)
    }

    func rememberSource(_ bundleID: String) {
        guard !bundleID.isEmpty, !mediaKnownSources.contains(bundleID) else { return }
        mediaKnownSources.append(bundleID)
    }

    @ObservationIgnored private var applyingLoginItem = false

    /// Login-item state can be changed from System Settings while MNotch is
    /// running. Adopt the OS value without feeding it back into register()/
    /// unregister(), so the toggle remains an honest status indicator.
    func refreshExternalState() {
        let enabled = SMAppService.mainApp.status == .enabled
        guard launchAtLogin != enabled else { return }
        applyingLoginItem = true
        launchAtLogin = enabled
        applyingLoginItem = false
    }

    private func applyLaunchAtLogin() {
        guard !loading, !applyingLoginItem else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            mnotchLog.error("launch-at-login toggle failed: \(error)")
            // Revert to the real status without re-entering this method —
            // didSet fires even on same-value assignment, and unregister()
            // throwing again would otherwise recurse unboundedly.
            applyingLoginItem = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            applyingLoginItem = false
        }
    }
}

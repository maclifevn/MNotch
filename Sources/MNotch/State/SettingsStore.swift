import Observation
import ServiceManagement

/// UserDefaults-backed settings, one property per Alcove-style toggle.
/// Every stored property persists via its didSet; defaults mirror Alcove's.
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    @ObservationIgnored private let d = UserDefaults.standard
    @ObservationIgnored private var loading = true

    /// Set by NotchWindowController to rebuild panels on display-ish toggles.
    @ObservationIgnored var onDisplayConfigChanged: (() -> Void)?

    private func save(_ key: String, _ value: Any) {
        guard !loading else { return }
        d.set(value, forKey: key)
    }

    // MARK: General

    var launchAtLogin: Bool { didSet { applyLaunchAtLogin() } }
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

    var notchWidthOffset: Double {
        didSet {
            save("tuning.width", notchWidthOffset)
            onDisplayConfigChanged?()
        }
    }
    var notchHeightOffset: Double {
        didSet {
            save("tuning.height", notchHeightOffset)
            onDisplayConfigChanged?()
        }
    }

    // MARK: Battery

    var batteryEnabled: Bool { didSet { save("battery.enabled", batteryEnabled) } }
    var batteryDuration: Double { didSet { save("battery.duration", batteryDuration) } }
    var batteryNotifyLowPower: Bool { didSet { save("battery.lowPower", batteryNotifyLowPower) } }
    var batteryWarnLow: Bool { didSet { save("battery.warnLow", batteryWarnLow) } }
    var batteryLowThreshold: Double { didSet { save("battery.threshold", batteryLowThreshold) } }
    var batterySoundOnLow: Bool { didSet { save("battery.sound", batterySoundOnLow) } }
    var batteryHideLabel: Bool { didSet { save("battery.hideLabel", batteryHideLabel) } }
    var batteryHidePercentage: Bool { didSet { save("battery.hidePct", batteryHidePercentage) } }

    // MARK: Connectivity

    var connectivityEnabled: Bool { didSet { save("bt.enabled", connectivityEnabled) } }
    var connectivityDuration: Double { didSet { save("bt.duration", connectivityDuration) } }
    var connectivityWarnLow: Bool { didSet { save("bt.warnLow", connectivityWarnLow) } }
    var connectivityLowThreshold: Double { didSet { save("bt.threshold", connectivityLowThreshold) } }
    var connectivitySoundOnLow: Bool { didSet { save("bt.sound", connectivitySoundOnLow) } }

    // MARK: Focus

    var focusEnabled: Bool { didSet { save("focus.enabled", focusEnabled) } }
    var focusDuration: Double { didSet { save("focus.duration", focusDuration) } }
    var focusSoundOnSleep: Bool { didSet { save("focus.sleepSound", focusSoundOnSleep) } }
    var focusReplaceWaveform: Bool { didSet { save("focus.replaceWaveform", focusReplaceWaveform) } }
    var focusHideLabel: Bool { didSet { save("focus.hideLabel", focusHideLabel) } }
    var focusAllowBattery: Bool { didSet { save("focus.allowBattery", focusAllowBattery) } }
    var focusAllowConnectivity: Bool { didSet { save("focus.allowBt", focusAllowConnectivity) } }
    var focusAllowDisplay: Bool { didSet { save("focus.allowDisplay", focusAllowDisplay) } }
    var focusAllowSound: Bool { didSet { save("focus.allowSound", focusAllowSound) } }

    // MARK: Display HUD (brightness)

    var displayHUDEnabled: Bool { didSet { save("display.enabled", displayHUDEnabled) } }
    var displayHUDDuration: Double { didSet { save("display.duration", displayHUDDuration) } }
    var displayBarStyle: HUDBarStyle { didSet { save("display.barStyle", displayBarStyle.rawValue) } }
    var displayShowPercentage: Bool { didSet { save("display.showPct", displayShowPercentage) } }
    var displayHideLabel: Bool { didSet { save("display.hideLabel", displayHideLabel) } }
    var displayAnimSpeed: AnimSpeed { didSet { save("display.animSpeed", displayAnimSpeed.rawValue) } }

    // MARK: Sound HUD (volume)

    var soundHUDEnabled: Bool { didSet { save("sound.enabled", soundHUDEnabled) } }
    var soundHUDDuration: Double { didSet { save("sound.duration", soundHUDDuration) } }
    var soundBarStyle: HUDBarStyle { didSet { save("sound.barStyle", soundBarStyle.rawValue) } }
    var soundShowPercentage: Bool { didSet { save("sound.showPct", soundShowPercentage) } }
    var soundHideLabel: Bool { didSet { save("sound.hideLabel", soundHideLabel) } }
    var soundAnimSpeed: AnimSpeed { didSet { save("sound.animSpeed", soundAnimSpeed.rawValue) } }
    var soundIconStyle: SoundIconStyle { didSet { save("sound.iconStyle", soundIconStyle.rawValue) } }

    // MARK: Now Playing

    var mediaEnabled: Bool { didSet { save("media.enabled", mediaEnabled) } }
    var mediaIdleDuration: Double { didSet { save("media.idleDuration", mediaIdleDuration) } }
    var mediaBadge: MediaBadgeStyle { didSet { save("media.badge", mediaBadge.rawValue) } }
    var mediaWaveformStyle: WaveformStyle { didSet { save("media.waveform", mediaWaveformStyle.rawValue) } }
    var mediaDisableCompactWaveform: Bool { didSet { save("media.noCompactWave", mediaDisableCompactWaveform) } }
    var mediaDisableArtworkFlip: Bool { didSet { save("media.noFlip", mediaDisableArtworkFlip) } }
    var mediaHideWhileSourceActive: Bool { didSet { save("media.hideSourceActive", mediaHideWhileSourceActive) } }
    var mediaHideTitleExtras: Bool { didSet { save("media.hideExtras", mediaHideTitleExtras) } }
    var mediaQuickAction: MediaQuickAction { didSet { save("media.quickAction", mediaQuickAction.rawValue) } }
    var mediaKnownSources: [String] { didSet { save("media.knownSources", mediaKnownSources) } }
    var mediaDisabledSources: [String] { didSet { save("media.disabledSources", mediaDisabledSources) } }

    // MARK: Calendar

    var calendarEnabled: Bool { didSet { save("cal.enabled", calendarEnabled) } }
    var calendarTimeBefore: Double { didSet { save("cal.timeBefore", calendarTimeBefore) } }
    var calendarSoundOnEvent: Bool { didSet { save("cal.eventSound", calendarSoundOnEvent) } }
    var calendarHourlyChime: Bool { didSet { save("cal.chime", calendarHourlyChime) } }
    var calendarUseColor: Bool { didSet { save("cal.useColor", calendarUseColor) } }
    var calendarDisableDuringEvents: Bool { didSet { save("cal.noDuringEvents", calendarDisableDuringEvents) } }
    var calendarEventIndicators: Bool { didSet { save("cal.indicators", calendarEventIndicators) } }
    var calendarMonthView: Bool { didSet { save("cal.monthView", calendarMonthView) } }
    var calendarQuickPeek: Bool { didSet { save("cal.peek", calendarQuickPeek) } }
    var calendarPeekBeforeStart: Bool { didSet { save("cal.peekBefore", calendarPeekBeforeStart) } }
    var calendarPeekWhenStarting: Bool { didSet { save("cal.peekStarting", calendarPeekWhenStarting) } }
    var calendarPeekDuration: Double { didSet { save("cal.peekDuration", calendarPeekDuration) } }
    var calendarColoredIndicator: Bool { didSet { save("cal.coloredIndicator", calendarColoredIndicator) } }
    var calendarDisabledCalendars: [String] { didSet { save("cal.disabled", calendarDisabledCalendars) } }
    /// calendarIdentifier -> CalendarUse rawValue (default both)
    var calendarUses: [String: String] { didSet { save("cal.uses", calendarUses) } }

    // MARK: Shelf & Lock Screen

    var shelfEnabled: Bool { didSet { save("shelf.enabled", shelfEnabled) } }

    var lockSoundOnLock: Bool { didSet { save("lock.soundLock", lockSoundOnLock) } }
    var lockSoundOnUnlock: Bool { didSet { save("lock.soundUnlock", lockSoundOnUnlock) } }
    var lockKeepAwake: Double { didSet { save("lock.keepAwake", lockKeepAwake) } }
    var lockEnabled: Bool { didSet { save("lock.enabled", lockEnabled) } }
    var lockShowOnScreenSaver: Bool { didSet { save("lock.screensaver", lockShowOnScreenSaver) } }
    var lockWidgetBattery: Bool { didSet { save("lock.widget.battery", lockWidgetBattery) } }
    var lockWidgetConnectivity: Bool { didSet { save("lock.widget.connectivity", lockWidgetConnectivity) } }
    var lockWidgetFocus: Bool { didSet { save("lock.widget.focus", lockWidgetFocus) } }
    var lockWidgetCalendar: Bool { didSet { save("lock.widget.calendar", lockWidgetCalendar) } }
    var lockNowPlaying: Bool { didSet { save("lock.nowPlaying", lockNowPlaying) } }
    var lockNowPlayingStyle: LockCardStyle { didSet { save("lock.npStyle", lockNowPlayingStyle.rawValue) } }
    var lockIdleDuration: Double { didSet { save("lock.idle", lockIdleDuration) } }
    var lockShowVolume: Bool { didSet { save("lock.volume", lockShowVolume) } }
    var lockOffset: Double { didSet { save("lock.offset", lockOffset) } }
    var lockAllowBattery: Bool { didSet { save("lock.allow.battery", lockAllowBattery) } }
    var lockAllowConnectivity: Bool { didSet { save("lock.allow.connectivity", lockAllowConnectivity) } }
    var lockAllowFocus: Bool { didSet { save("lock.allow.focus", lockAllowFocus) } }
    var lockAllowDisplay: Bool { didSet { save("lock.allow.display", lockAllowDisplay) } }
    var lockAllowSound: Bool { didSet { save("lock.allow.sound", lockAllowSound) } }

    // Agent monitor
    var agentEnabled: Bool { didSet { save("agent.enabled", agentEnabled) } }
    var agentSound: Bool { didSet { save("agent.sound", agentSound) } }
    var agentDuration: Double { didSet { save("agent.duration", agentDuration) } }
    var agentAutoExpand: Bool { didSet { save("agent.autoExpand", agentAutoExpand) } }

    // MARK: - Init / load

    private init() {
        // Local shadow so the nested helpers don't touch self before
        // initialization completes.
        let d = UserDefaults.standard
        func flag(_ key: String, _ fallback: Bool, legacy: String? = nil) -> Bool {
            if d.object(forKey: key) != nil { return d.bool(forKey: key) }
            if let legacy, d.object(forKey: legacy) != nil { return d.bool(forKey: legacy) }
            return fallback
        }
        func num(_ key: String, _ fallback: Double) -> Double {
            d.object(forKey: key) != nil ? d.double(forKey: key) : fallback
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
        hideInFullscreen = flag("general.hideFullscreen", true)
        hideInMissionControl = flag("general.hideMissionControl", true)
        hideWhileGaming = flag("general.hideGaming", false)
        hideFromScreenCapture = flag("general.hideCapture", false)
        forceSimulatedNotch = flag("general.forceNotch", d.bool(forKey: "display.fakeNotch"))
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
        notchWidthOffset = num("tuning.width", 0)
        notchHeightOffset = num("tuning.height", 0)

        batteryEnabled = flag("battery.enabled", true, legacy: "feature.battery")
        batteryDuration = num("battery.duration", 5)
        batteryNotifyLowPower = flag("battery.lowPower", true)
        batteryWarnLow = flag("battery.warnLow", true)
        batteryLowThreshold = num("battery.threshold", 10)
        batterySoundOnLow = flag("battery.sound", false)
        batteryHideLabel = flag("battery.hideLabel", false)
        batteryHidePercentage = flag("battery.hidePct", false)

        connectivityEnabled = flag("bt.enabled", true, legacy: "feature.bluetooth")
        connectivityDuration = num("bt.duration", 5)
        connectivityWarnLow = flag("bt.warnLow", true)
        connectivityLowThreshold = num("bt.threshold", 20)
        connectivitySoundOnLow = flag("bt.sound", false)

        focusEnabled = flag("focus.enabled", true)
        focusDuration = num("focus.duration", 5)
        focusSoundOnSleep = flag("focus.sleepSound", false)
        focusReplaceWaveform = flag("focus.replaceWaveform", false)
        focusHideLabel = flag("focus.hideLabel", false)
        focusAllowBattery = flag("focus.allowBattery", true)
        focusAllowConnectivity = flag("focus.allowBt", true)
        focusAllowDisplay = flag("focus.allowDisplay", true)
        focusAllowSound = flag("focus.allowSound", true)

        displayHUDEnabled = flag("display.enabled", true, legacy: "feature.hud")
        displayHUDDuration = num("display.duration", 1.5)
        displayBarStyle = opt("display.barStyle", HUDBarStyle.white)
        displayShowPercentage = flag("display.showPct", false)
        displayHideLabel = flag("display.hideLabel", false)
        displayAnimSpeed = opt("display.animSpeed", AnimSpeed.fast)

        soundHUDEnabled = flag("sound.enabled", true, legacy: "feature.hud")
        soundHUDDuration = num("sound.duration", 1.5)
        soundBarStyle = opt("sound.barStyle", HUDBarStyle.white)
        soundShowPercentage = flag("sound.showPct", false)
        soundHideLabel = flag("sound.hideLabel", false)
        soundAnimSpeed = opt("sound.animSpeed", AnimSpeed.fast)
        soundIconStyle = opt("sound.iconStyle", SoundIconStyle.device)

        mediaEnabled = flag("media.enabled", true, legacy: "feature.media")
        mediaIdleDuration = num("media.idleDuration", 3)
        mediaBadge = opt("media.badge", MediaBadgeStyle.none)
        mediaWaveformStyle = opt("media.waveform", WaveformStyle.colored)
        mediaDisableCompactWaveform = flag("media.noCompactWave", false)
        mediaDisableArtworkFlip = flag("media.noFlip", false)
        mediaHideWhileSourceActive = flag("media.hideSourceActive", false)
        mediaHideTitleExtras = flag("media.hideExtras", false)
        mediaQuickAction = opt("media.quickAction", MediaQuickAction.shuffle)
        mediaKnownSources = d.stringArray(forKey: "media.knownSources") ?? []
        mediaDisabledSources = d.stringArray(forKey: "media.disabledSources") ?? []

        calendarEnabled = flag("cal.enabled", true, legacy: "feature.calendar")
        calendarTimeBefore = num("cal.timeBefore", 15)
        calendarSoundOnEvent = flag("cal.eventSound", false)
        calendarHourlyChime = flag("cal.chime", false)
        calendarUseColor = flag("cal.useColor", true)
        calendarDisableDuringEvents = flag("cal.noDuringEvents", false)
        calendarEventIndicators = flag("cal.indicators", false)
        calendarMonthView = flag("cal.monthView", false)
        calendarQuickPeek = flag("cal.peek", true)
        calendarPeekBeforeStart = flag("cal.peekBefore", false)
        calendarPeekWhenStarting = flag("cal.peekStarting", true)
        calendarPeekDuration = num("cal.peekDuration", 4)
        calendarColoredIndicator = flag("cal.coloredIndicator", true)
        calendarDisabledCalendars = d.stringArray(forKey: "cal.disabled") ?? []
        calendarUses = (d.dictionary(forKey: "cal.uses") as? [String: String]) ?? [:]

        shelfEnabled = flag("shelf.enabled", true, legacy: "feature.shelf")
        lockSoundOnLock = flag("lock.soundLock", false)
        lockSoundOnUnlock = flag("lock.soundUnlock", false)
        lockKeepAwake = num("lock.keepAwake", 0)
        lockEnabled = flag("lock.enabled", true)
        lockShowOnScreenSaver = flag("lock.screensaver", false)
        lockWidgetBattery = flag("lock.widget.battery", true)
        lockWidgetConnectivity = flag("lock.widget.connectivity", true)
        lockWidgetFocus = flag("lock.widget.focus", true)
        lockWidgetCalendar = flag("lock.widget.calendar", false)
        lockNowPlaying = flag("lock.nowPlaying", true)
        lockNowPlayingStyle = opt("lock.npStyle", LockCardStyle.glass)
        lockIdleDuration = num("lock.idle", 10)
        lockShowVolume = flag("lock.volume", false)
        lockOffset = num("lock.offset", 0)
        lockAllowBattery = flag("lock.allow.battery", true)
        lockAllowConnectivity = flag("lock.allow.connectivity", true)
        lockAllowFocus = flag("lock.allow.focus", true)
        lockAllowDisplay = flag("lock.allow.display", true)
        lockAllowSound = flag("lock.allow.sound", true)

        agentEnabled = flag("agent.enabled", false)
        agentSound = flag("agent.sound", true)
        agentDuration = num("agent.duration", 4)
        agentAutoExpand = flag("agent.autoExpand", true)

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

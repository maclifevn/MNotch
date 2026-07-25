import EventKit
import Observation

/// Immutable seam between persistence/UI and lifecycle policy. Tests and
/// future settings backends can exercise demand calculation without touching
/// UserDefaults or constructing hardware services.
struct FeatureFlags: Equatable, Sendable {
    var mediaEnabled = false
    var soundHUDEnabled = false
    var displayHUDEnabled = false
    var batteryEnabled = false
    var connectivityEnabled = false
    var calendarEnabled = false
    var idleMostRecent = false
    var idleActivity: IdleActivity = .none
    var hideInFullscreen = false
    var hideInMissionControl = false
    var hideWhileGaming = false
    var mediaHideWhileSourceActive = false
    var focusEnabled = false
    var agentEnabled = false
    var lockEnabled = false
    var lockNowPlaying = false
    var lockShowVolume = false
    var lockWidgetBattery = false
    var lockWidgetConnectivity = false
    var lockWidgetCalendar = false
    var lockWidgetFocus = false

    @MainActor
    static func capture(_ settings: SettingsStore) -> FeatureFlags {
        FeatureFlags(
            mediaEnabled: settings.mediaEnabled,
            soundHUDEnabled: settings.soundHUDEnabled,
            displayHUDEnabled: settings.displayHUDEnabled,
            batteryEnabled: settings.batteryEnabled,
            connectivityEnabled: settings.connectivityEnabled,
            calendarEnabled: settings.calendarEnabled,
            idleMostRecent: settings.idleMostRecent,
            idleActivity: settings.idleActivity,
            hideInFullscreen: settings.hideInFullscreen,
            hideInMissionControl: settings.hideInMissionControl,
            hideWhileGaming: settings.hideWhileGaming,
            mediaHideWhileSourceActive: settings.mediaHideWhileSourceActive,
            focusEnabled: settings.focusEnabled,
            agentEnabled: settings.agentEnabled,
            lockEnabled: settings.lockEnabled,
            lockNowPlaying: settings.lockNowPlaying,
            lockShowVolume: settings.lockShowVolume,
            lockWidgetBattery: settings.lockWidgetBattery,
            lockWidgetConnectivity: settings.lockWidgetConnectivity,
            lockWidgetCalendar: settings.lockWidgetCalendar,
            lockWidgetFocus: settings.lockWidgetFocus
        )
    }
}

/// The effective runtime cost of each feature. A service can have more than one
/// consumer (for example Media powers both Now Playing and the lock-screen
/// card), so lifecycle decisions belong here instead of in individual views.
@MainActor
struct FeatureDemand: Equatable {
    let media: Bool
    let audio: Bool
    let displayControls: Bool
    let keys: Bool
    let power: Bool
    let bluetooth: Bool
    let calendar: Bool
    let occlusion: Bool
    let focus: Bool
    let agents: Bool
    let quota: Bool

    init(settings: SettingsStore) {
        self.init(flags: .capture(settings))
    }

    init(flags: FeatureFlags) {
        let lock = flags.lockEnabled
        media = flags.mediaEnabled || (lock && flags.lockNowPlaying)
        audio = flags.soundHUDEnabled || media || (lock && flags.lockShowVolume)
        displayControls = flags.displayHUDEnabled
        // When Accessibility is already granted, the same fail-open event tap
        // can observe (not swallow) media keys and keep Now Playing in sync.
        keys = media || flags.soundHUDEnabled || flags.displayHUDEnabled
        power = flags.batteryEnabled || (lock && flags.lockWidgetBattery)
        bluetooth = flags.connectivityEnabled
            || (lock && flags.lockWidgetConnectivity)
        calendar = flags.calendarEnabled
            || (lock && flags.lockWidgetCalendar)
            || flags.idleMostRecent
            || flags.idleActivity == .calendar
            || flags.idleActivity == .duo
        occlusion = flags.hideInFullscreen
            || flags.hideInMissionControl
            || flags.hideWhileGaming
            || (media && flags.mediaHideWhileSourceActive)
        focus = flags.focusEnabled || (lock && flags.lockWidgetFocus)
        agents = flags.agentEnabled
        quota = flags.agentEnabled
    }

    private init(
        media: Bool, audio: Bool, displayControls: Bool, keys: Bool,
        power: Bool, bluetooth: Bool, calendar: Bool, occlusion: Bool,
        focus: Bool, agents: Bool, quota: Bool
    ) {
        self.media = media
        self.audio = audio
        self.displayControls = displayControls
        self.keys = keys
        self.power = power
        self.bluetooth = bluetooth
        self.calendar = calendar
        self.occlusion = occlusion
        self.focus = focus
        self.agents = agents
        self.quota = quota
    }

    func suspended(_ suspended: Bool) -> FeatureDemand {
        guard suspended else { return self }
        return FeatureDemand(
            media: false,
            audio: false,
            displayControls: false,
            keys: false,
            power: power,
            bluetooth: bluetooth,
            calendar: false,
            // Occlusion and quota stay up across display sleep on purpose:
            // stopping occlusion un-hides panels (a notch flash over a
            // fullscreen app on wake), and restarting quota relaunches the CLI
            // + codex subprocess every wake, bypassing its own fetch backoff.
            // Both poll cheaply/infrequently, so leaving them running is
            // strictly better than the resume-time churn.
            occlusion: occlusion,
            focus: false,
            agents: agents,
            quota: quota
        )
    }
}

@MainActor
private struct CalendarRuntimeConfiguration: Equatable {
    let enabled: Bool
    let quickPeek: Bool
    let beforeStart: Bool
    let whenStarting: Bool
    let hourlyChime: Bool
    let monthView: Bool
    let timeBefore: Double
    let disabledCalendars: [String]
    let uses: [String: String]

    init(_ settings: SettingsStore) {
        enabled = settings.calendarEnabled
        quickPeek = settings.calendarQuickPeek
        beforeStart = settings.calendarPeekBeforeStart
        whenStarting = settings.calendarPeekWhenStarting
        hourlyChime = settings.calendarHourlyChime
        monthView = settings.calendarMonthView
        timeBefore = settings.calendarTimeBefore
        disabledCalendars = settings.calendarDisabledCalendars
        uses = settings.calendarUses
    }
}

@MainActor
private struct LockRuntimeConfiguration: Equatable {
    let enabled: Bool
    let showOnScreenSaver: Bool
    let idleDuration: Double
    let offset: Double

    init(_ settings: SettingsStore) {
        enabled = settings.lockEnabled
        showOnScreenSaver = settings.lockShowOnScreenSaver
        idleDuration = settings.lockIdleDuration
        offset = settings.lockOffset
    }
}

@MainActor
private struct FeatureSnapshot: Equatable {
    let demand: FeatureDemand
    let calendar: CalendarRuntimeConfiguration
    let lock: LockRuntimeConfiguration

    init(settings: SettingsStore) {
        demand = FeatureDemand(settings: settings)
        calendar = CalendarRuntimeConfiguration(settings)
        lock = LockRuntimeConfiguration(settings)
    }
}

/// Observes Settings once and applies all service start/stop/reconfigure side
/// effects. This keeps Settings views declarative and guarantees changes made
/// from onboarding, tests, or future UI surfaces behave identically.
@MainActor
final class FeatureCoordinator {
    private unowned let services: AppServices
    private var current: FeatureSnapshot?
    private var activeDemand: FeatureDemand?
    private var running = false
    private var isSuspended = false
    /// One calm Accessibility reminder per launch. Without this the pop re-fires
    /// on every display wake (keys demand cycles off→on through suspension).
    private var accessibilityPromptShown = false

    init(services: AppServices) {
        self.services = services
    }

    func start() {
        guard !running else { return }
        running = true
        services.lockScreen.start() // event-driven and needed for notification policy
        observeAndApply()
    }

    func stop() {
        guard running else { return }
        running = false
        current = nil
        activeDemand = nil
        services.media.stop()
        services.audio.stop()
        services.keys.stop()
        services.brightness.stop()
        services.backlight.stop()
        services.power.stop()
        services.bluetooth.stop()
        services.calendar.stop()
        services.occlusion.stop()
        services.focus.stop()
        services.agents.stop()
        services.quota.stop()
        services.lockScreen.stop()
    }

    /// Immediate application for callers that have just changed a setting. The
    /// Observation callback will also fire, but equality makes that pass free.
    func refresh() {
        guard running else { return }
        apply(FeatureSnapshot(settings: .shared))
    }

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if let current { apply(current) }
    }

    /// Permissions can change while Settings is open. Retry services whose
    /// first start deliberately degraded instead of requiring an app relaunch.
    func applicationDidBecomeActive() {
        guard running else { return }
        SettingsStore.shared.refreshExternalState()
        services.accessibility.refresh()
        services.calendar.permissionMayHaveChanged()
        if services.accessibility.isGranted,
           activeDemand?.keys == true,
           !services.keys.tapActive {
            services.keys.start()
        }
    }

    func accessibilityDidChange(_ granted: Bool) {
        guard running else { return }
        if granted, activeDemand?.keys == true {
            services.keys.start()
        } else if !granted {
            services.keys.stop()
        }
    }

    private func observeAndApply() {
        guard running else { return }
        let snapshot = withObservationTracking {
            FeatureSnapshot(settings: .shared)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAndApply() }
        }
        apply(snapshot)
    }

    private func apply(_ next: FeatureSnapshot) {
        let previous = current
        current = next
        let demand = next.demand.suspended(isSuspended)
        let old = activeDemand
        activeDemand = demand
        services.accessibility.setMonitoringNeeded(demand.keys)

        transition(old?.media, demand.media, start: services.media.start, stop: services.media.stop)
        transition(old?.audio, demand.audio, start: services.audio.start, stop: services.audio.stop)
        if services.accessibility.isRequiredForEnabledFeatures,
           !accessibilityPromptShown {
            accessibilityPromptShown = true
            services.showPop?(.accessibility)
        }
        transition(old?.keys, demand.keys, start: services.keys.start, stop: services.keys.stop)
        transition(old?.displayControls, demand.displayControls, start: {
            self.services.brightness.start()
            self.services.brightness.startObserving()
            self.services.backlight.start()
        }, stop: {
            self.services.brightness.stop()
            self.services.backlight.stop()
        })
        transition(old?.power, demand.power, start: services.power.start, stop: services.power.stop)
        transition(old?.bluetooth, demand.bluetooth, start: services.bluetooth.start, stop: services.bluetooth.stop)
        transition(old?.occlusion, demand.occlusion, start: services.occlusion.start, stop: services.occlusion.stop)
        transition(old?.focus, demand.focus, start: services.focus.start, stop: services.focus.stop)

        if old?.calendar != demand.calendar {
            if demand.calendar {
                // Never trigger TCC from launch. If access already exists, start
                // eagerly; otherwise the first Calendar UI interaction asks.
                if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
                    services.calendar.ensureStarted()
                }
            } else {
                services.calendar.stop()
            }
        }
        if demand.calendar, previous?.calendar != next.calendar {
            services.calendar.reconfigure()
        }

        if old?.agents != demand.agents {
            if demand.agents {
                // Avoid touching agent config/scripts on normal launches when
                // the optional integration is disabled.
                ClaudeHookInstaller.refreshScripts()
                services.agents.start()
            } else {
                services.agents.stop()
                services.collapseIfIdle?()
            }
        }
        if old?.quota != demand.quota {
            demand.quota ? services.quota.start() : services.quota.stop()
        }

        if previous?.lock != next.lock {
            services.lockScreen.reconfigure()
        }
    }

    private func transition(
        _ previous: Bool?,
        _ next: Bool,
        start: () -> Void,
        stop: () -> Void
    ) {
        guard previous != next else { return }
        next ? start() : stop()
    }
}

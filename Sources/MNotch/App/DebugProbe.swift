import AppKit
import SwiftUI

/// Test hooks: `mnotch.debug.dump` logs a full state snapshot,
/// `mnotch.debug.settings` opens the settings window. Driven from the CLI
/// via DistributedNotificationCenter for headless verification.
@MainActor
enum DebugProbe {
    static func install(controller: NotchWindowController) {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: NSNotification.Name("mnotch.debug.dump"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in dump(controller: controller) }
        }
        center.addObserver(
            forName: NSNotification.Name("mnotch.debug.settings"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in SettingsWindowController.shared.show() }
        }
    }

    private static func dump(controller: NotchWindowController) {
        let s = SettingsStore.shared
        let services = AppServices.shared

        var lines: [String] = []
        lines.append("== MNotch state dump ==")
        for (index, panel) in controller.debugPanels.enumerated() {
            lines.append("panel[\(index)] frame=\(panel.frame) alpha=\(panel.alphaValue) sharing=\(panel.sharingType.rawValue)")
        }
        for (index, vm) in controller.debugViewModels.enumerated() {
            lines.append("vm[\(index)] status=\(String(describing: vm.status)) idle=\(String(describing: vm.resolvedIdle)) size=\(vm.visualSize) hovering=\(vm.isHovering) mediaActive=\(vm.mediaActive) geometry=\(vm.geometry.notchWidth)x\(vm.geometry.notchHeight)")
        }
        let p = services.media.playback
        lines.append("media title=\"\(p.title)\" playing=\(p.isPlaying) app=\(p.bundleIdentifier) active=\(services.media.hasActiveMedia) artwork=\(services.media.artwork != nil)")
        lines.append("audio vol=\(services.audio.volume) muted=\(services.audio.muted) out=\(services.audio.outputSymbol)")
        lines.append("brightness avail=\(services.brightness.available) val=\(services.brightness.brightness) backlight avail=\(services.backlight.available)")
        lines.append("keys tap=\(services.keys.tapActive)")
        lines.append("occlusion hide=\(services.occlusion.shouldHide) front=\(services.occlusion.frontmostBundleID ?? "-")")
        lines.append("focus avail=\(services.focus.available) mode=\(services.focus.current?.name ?? "-")")
        lines.append("calendar auth=\(services.calendar.authorized) today=\(services.calendar.today.count) upcoming=\(services.calendar.upcoming.count) monthDays=\(services.calendar.monthEventDays.count) cals=\(services.calendar.calendars.count)")
        lines.append("settings idle=\(s.idleActivity.rawValue) mostRecent=\(s.idleMostRecent) hideFS=\(s.hideInFullscreen) hideMC=\(s.hideInMissionControl) gaming=\(s.hideWhileGaming) capture=\(s.hideFromScreenCapture) forceNotch=\(s.forceSimulatedNotch) target=\(s.displayTarget)")
        lines.append("settings outline=\(s.contrastOutline) blur=\(s.progressiveBlur) haptic=\(s.hapticFeedback) hoverExpand=\(s.expandOnHover) tuning=\(s.notchWidthOffset)/\(s.notchHeightOffset)")
        lines.append("settings battery=\(s.batteryEnabled)/\(s.batteryDuration)s/th\(s.batteryLowThreshold) bt=\(s.connectivityEnabled)/th\(s.connectivityLowThreshold) focus=\(s.focusEnabled) soundHUD=\(s.soundHUDEnabled)/\(s.soundBarStyle.rawValue)/\(s.soundAnimSpeed.rawValue) dispHUD=\(s.displayHUDEnabled)/\(s.displayBarStyle.rawValue)")
        lines.append("settings media=\(s.mediaEnabled) idleDur=\(s.mediaIdleDuration) wave=\(s.mediaWaveformStyle.rawValue) quick=\(s.mediaQuickAction.rawValue) badge=\(s.mediaBadge.rawValue) sources=\(s.mediaKnownSources) disabled=\(s.mediaDisabledSources)")
        lines.append("settings cal=\(s.calendarEnabled) peek=\(s.calendarQuickPeek)/\(s.calendarPeekBeforeStart)/\(s.calendarPeekWhenStarting) before=\(s.calendarTimeBefore)m month=\(s.calendarMonthView) shelf=\(s.shelfEnabled)")

        for line in lines {
            mnotchLog.notice("DUMP \(line, privacy: .public)")
        }
    }
}

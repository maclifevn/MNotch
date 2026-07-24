import AppKit
import SwiftUI

/// The lock screen overlay: a panel positioned in the lower third of the
/// built-in screen, at a window level ABOVE the lock shield (the modern lock
/// screen is a shield window inside the user session, so higher-level windows
/// composite over it — the same trick Alcove uses).
@MainActor
final class LockOverlayController {
    private var panel: NSPanel?
    private var idleTask: Task<Void, Never>?

    func setVisible(_ visible: Bool) {
        if visible {
            // Screensaver start/stop notifications re-fire this while locked;
            // rebuilding a visible overlay would flicker and restart the idle
            // timer, so a live overlay stays put.
            guard panel == nil else { return }
            show()
        } else {
            hide()
        }
    }

    /// Apply position and idle-timeout changes while the overlay is visible.
    func reconfigure() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
        guard let screen else { return }
        let settings = SettingsStore.shared
        let origin = NSPoint(
            x: screen.frame.midX - panel.frame.width / 2,
            y: screen.frame.minY + screen.frame.height * 0.16 + settings.lockOffset
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Anim.reduceMotion ? 0 : 0.2
            panel.animator().setFrameOrigin(origin)
        }
        scheduleIdleTimeout(minutes: settings.lockIdleDuration)
    }

    private func show() {
        hide()

        // Private WindowServer APIs are optional by design. Fail closed if a
        // macOS update removes or rejects them; never leak a normal high-level
        // panel into the unlocked desktop as a fake lock overlay.
        let skyLight = SkyLightOperator.shared
        guard skyLight.available else { return }

        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
        guard let screen else { return }

        let settings = SettingsStore.shared
        let size = NSSize(width: 420, height: 240)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.minY + screen.frame.height * 0.16 + settings.lockOffset,
            width: size.width,
            height: size.height
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: Int(Int32.max) - 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The modern lock screen composites in a secure WindowServer space;
        // this flag plus SkyLight space delegation are what put us on it.
        panel.canBecomeVisibleWithoutLogin = true
        panel.contentView = NSHostingView(rootView: LockOverlayView())
        panel.alphaValue = 0
        // Order front BEFORE delegating to the lock space: SLSSpaceAddWindows…
        // moves the window off whatever space it's currently on, so if we moved
        // it first, orderFront would re-bind it to the active desktop space and
        // undo the lock-space membership. alphaValue is 0 here, so this on-desktop
        // moment never flashes; we still fail closed by ordering out on refusal.
        panel.orderFrontRegardless()
        guard skyLight.addToLockSpace(panel) else {
            mnotchLog.error("SkyLight could not attach lock overlay window")
            panel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Anim.reduceMotion ? 0.12 : 0.5
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        mnotchLog.notice("lock overlay shown level=\(panel.level.rawValue)")

        // Hide after the idle duration so the display can rest.
        scheduleIdleTimeout(minutes: settings.lockIdleDuration)
    }

    private func scheduleIdleTimeout(minutes: Double) {
        idleTask?.cancel()
        idleTask = nil
        guard panel != nil, minutes > 0 else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        idleTask?.cancel()
        idleTask = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Anim.reduceMotion ? 0.1 : 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
            }
        })
    }
}

/// Widget capsule row + Now Playing card, styled per settings.
struct LockOverlayView: View {
    private let services = AppServices.shared
    private var settings: SettingsStore { .shared }

    var body: some View {
        VStack(spacing: 14) {
            widgetRow
            if settings.lockNowPlaying, services.media.hasActiveMedia {
                LockNowPlayingCard()
            }
            Spacer(minLength: 0)
        }
        .frame(width: 420, height: 240, alignment: .top)
    }

    private var widgetRow: some View {
        HStack(spacing: 8) {
            if settings.lockWidgetBattery {
                LockPill(
                    symbol: services.power.onAC ? "bolt.fill" : "battery.75percent",
                    text: "\(services.power.percentage)%",
                    tint: services.power.onAC ? .green : .white
                )
            }
            if settings.lockWidgetConnectivity,
               let device = services.bluetooth.connectedDeviceSummaries.first {
                LockPill(symbol: device.symbol, text: device.name, tint: .white)
            }
            if settings.lockWidgetFocus, let mode = services.focus.current {
                LockPill(symbol: mode.symbol, text: mode.name, tint: .purple)
            }
            if settings.lockWidgetCalendar, let event = services.calendar.nextEvent {
                LockPill(
                    symbol: "calendar",
                    text: event.title,
                    tint: Color(red: event.colorRed, green: event.colorGreen, blue: event.colorBlue)
                )
            }
        }
    }
}

struct LockPill: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.35), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: 150)
    }
}

/// Alcove-style Now Playing card for the lock screen: Glass / Clear / Frosted.
struct LockNowPlayingCard: View {
    private let services = AppServices.shared
    private var settings: SettingsStore { .shared }

    var body: some View {
        let media = services.media
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ArtworkView(
                    image: media.artwork,
                    cornerRadius: 10,
                    identity: media.playback.title
                )
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.playback.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(media.playback.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VisualizerView(
                    isPlaying: media.playback.isPlaying,
                    color: media.accentColor
                )
                .frame(width: 18, height: 13)
            }

            if settings.lockShowVolume {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                    CapsuleSlider(
                        value: services.audio.volume,
                        onScrub: { services.audio.setVolume($0) },
                        onCommit: { services.audio.setVolume($0) }
                    )
                    .frame(height: 6)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(settings.lockNowPlayingStyle == .glass ? 0.18 : 0), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var cardBackground: some View {
        switch settings.lockNowPlayingStyle {
        case .glass:
            ZStack {
                VisualEffectView(material: .hudWindow)
                Color.white.opacity(0.06)
            }
        case .clear:
            Color.black.opacity(0.32)
        case .frosted:
            VisualEffectView(material: .fullScreenUI)
        }
    }
}

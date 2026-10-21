import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import MNotch

final class CoreLogicTests: XCTestCase {
    func testLanguageDefaultsToTheMacSystemPreference() {
        XCTAssertEqual(AppLanguage.resolvedPreference(from: nil), .system)
        XCTAssertEqual(AppLanguage.resolvedPreference(from: "unknown"), .system)
        XCTAssertEqual(AppLanguage.resolvedPreference(from: "vi"), .vietnamese)
        XCTAssertEqual(AppLanguage.resolvedPreference(from: "en"), .english)
    }

    func testLanguageRestartPromptTracksTheActuallyLaunchedLanguage() {
        XCTAssertFalse(AppLanguageRestartPolicy.requiresRestart(
            selected: .vietnamese,
            launched: .vietnamese
        ))
        XCTAssertTrue(AppLanguageRestartPolicy.requiresRestart(
            selected: .vietnamese,
            launched: .english
        ))
        XCTAssertFalse(AppLanguageRestartPolicy.requiresRestart(
            selected: .system,
            launched: .system
        ))
    }

    func testShelfDragCarriesTheWholeSelectionInTrayOrder() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let c = URL(fileURLWithPath: "/tmp/c.png")
        let available = [a, b, c]

        XCTAssertEqual(
            ShelfDragSelection.urls(
                dragged: c,
                selection: [a, c],
                available: available
            ),
            [a, c]
        )
        XCTAssertEqual(
            ShelfDragSelection.urls(
                dragged: b,
                selection: [a, c],
                available: available
            ),
            [b]
        )
    }

    func testShelfRejectsItsOwnOutgoingDragButAcceptsExternalFiles() {
        XCTAssertTrue(ShelfDropPolicy.accepts(
            featureEnabled: true,
            outgoingShelfDrag: false
        ))
        XCTAssertFalse(ShelfDropPolicy.accepts(
            featureEnabled: true,
            outgoingShelfDrag: true
        ))
        XCTAssertFalse(ShelfDropPolicy.accepts(
            featureEnabled: false,
            outgoingShelfDrag: false
        ))
    }

    func testShelfOnlyClearsAfterAnEnabledSuccessfulDrag() {
        XCTAssertTrue(ShelfDragCompletionPolicy.shouldClear(
            settingEnabled: true,
            operationSucceeded: true
        ))
        XCTAssertFalse(ShelfDragCompletionPolicy.shouldClear(
            settingEnabled: false,
            operationSucceeded: true
        ))
        XCTAssertFalse(ShelfDragCompletionPolicy.shouldClear(
            settingEnabled: true,
            operationSucceeded: false
        ))
    }

    func testClaudeSearchPathKeepsFallbacksAndRemovesDuplicates() {
        XCTAssertEqual(
            ClaudeUsageClient.mergeSearchPaths([
                "/custom/bin:/usr/bin",
                "/usr/bin:/Users/test/.local/bin",
                "/custom/bin:/bin",
            ]),
            "/custom/bin:/usr/bin:/Users/test/.local/bin:/bin"
        )
    }

    func testPreferredPlayerPlayNeverTargetsAnUnconfirmedSource() {
        let mmusic = "com.mtube.mmusic"

        XCTAssertFalse(MediaRemoteService.shouldSendPreferredPlay(
            preferredBundleID: mmusic,
            observedBundleID: nil,
            observedPlaying: false
        ))
        XCTAssertFalse(MediaRemoteService.shouldSendPreferredPlay(
            preferredBundleID: mmusic,
            observedBundleID: "com.apple.Music",
            observedPlaying: false
        ))
        XCTAssertFalse(MediaRemoteService.shouldSendPreferredPlay(
            preferredBundleID: mmusic,
            observedBundleID: mmusic,
            observedPlaying: true
        ))
        XCTAssertTrue(MediaRemoteService.shouldSendPreferredPlay(
            preferredBundleID: mmusic,
            observedBundleID: mmusic,
            observedPlaying: false
        ))
    }

    func testPausedSignalWinsAStalePlayingField() {
        XCTAssertFalse(MediaRemoteService.reportedPlaying(
            flag: true,
            playbackRate: 0
        ))
        XCTAssertFalse(MediaRemoteService.reportedPlaying(
            flag: false,
            playbackRate: 1
        ))
        XCTAssertTrue(MediaRemoteService.reportedPlaying(
            flag: true,
            playbackRate: 1
        ))
    }

    func testStaleConfirmationCannotImmediatelyUndoOptimisticPause() {
        let now = Date()
        XCTAssertTrue(MediaRemoteService.shouldHoldOptimisticState(
            desired: false,
            reported: true,
            deadline: now.addingTimeInterval(1),
            now: now
        ))
        XCTAssertFalse(MediaRemoteService.shouldHoldOptimisticState(
            desired: false,
            reported: true,
            deadline: now,
            now: now
        ))
    }

    func testTimestampOnlyMediaPollDoesNotRepublishTheViewTree() {
        let now = Date()
        var current = MediaPlayback()
        current.title = "Track"
        current.artist = "Artist"
        current.duration = 180
        current.elapsedTime = 40
        current.timestamp = now.addingTimeInterval(-2)
        current.playbackRate = 1
        current.isPlaying = true

        var candidate = current
        candidate.elapsedTime = 42
        candidate.timestamp = now

        XCTAssertFalse(MediaRemoteService.shouldPublishPlayback(
            current: current,
            candidate: candidate,
            at: now
        ))
        candidate.isPlaying = false
        XCTAssertTrue(MediaRemoteService.shouldPublishPlayback(
            current: current,
            candidate: candidate,
            at: now
        ))
    }

    func testSimulatedNotchPolicyFollowsHardwareAndUserOverride() {
        XCTAssertTrue(SimulatedNotchPolicy.isEnabled(
            force: false,
            hasPhysicalNotch: false
        ))
        XCTAssertFalse(SimulatedNotchPolicy.isEnabled(
            force: false,
            hasPhysicalNotch: true
        ))
        XCTAssertTrue(SimulatedNotchPolicy.isEnabled(
            force: true,
            hasPhysicalNotch: true
        ))
    }

    @MainActor
    func testAutoHideKeepsPhysicalNotchAndInteractiveContentVisible() {
        let settings = SettingsStore.shared
        let previous = settings.autoHideSimulatedNotch
        let hover = settings.expandOnHover
        settings.expandOnHover = false
        defer {
            settings.autoHideSimulatedNotch = previous
            settings.expandOnHover = hover
        }
        let simulated = NotchViewModel(geometry: .init(
            notchWidth: 185, notchHeight: 32, isPhysical: false
        ))
        let physical = NotchViewModel(geometry: .init(
            notchWidth: 185, notchHeight: 32, isPhysical: true
        ))
        settings.autoHideSimulatedNotch = false
        XCTAssertFalse(simulated.isAutoHidden)
        settings.autoHideSimulatedNotch = true
        XCTAssertTrue(simulated.isAutoHidden)
        XCTAssertFalse(physical.isAutoHidden)
        let bounds = CGRect(x: 0, y: 0, width: 700, height: 448)
        let revealArea = simulated.interactiveRect(in: bounds, flipped: true)
        XCTAssertTrue(revealArea.contains(CGPoint(x: 350, y: 1)))
        XCTAssertFalse(revealArea.contains(CGPoint(x: 10, y: 200)))
        simulated.setPointerInside(true)
        XCTAssertFalse(simulated.isAutoHidden)
        simulated.setPointerInside(false)
        XCTAssertTrue(simulated.isAutoHidden)
        simulated.showHUD(.volume, value: 0.5)
        XCTAssertFalse(simulated.isAutoHidden)
        simulated.collapse()
        simulated.showPop(.accessibility)
        XCTAssertFalse(simulated.isAutoHidden)
        simulated.dismissAccessibilityNotice()
        XCTAssertTrue(simulated.isAutoHidden)
        simulated.expand(.media)
        XCTAssertFalse(simulated.isAutoHidden)
        simulated.collapse()
        XCTAssertTrue(simulated.isAutoHidden)
    }

    @MainActor
    func testNativePanelRevealsHiddenNotchAndPassesOutsideClicksThrough() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No display in test host") }
        let settings = SettingsStore.shared
        let autoHide = settings.autoHideSimulatedNotch
        let hover = settings.expandOnHover
        settings.autoHideSimulatedNotch = true
        settings.expandOnHover = false
        defer {
            settings.autoHideSimulatedNotch = autoHide
            settings.expandOnHover = hover
        }
        let model = NotchViewModel(geometry: .init(
            notchWidth: 185, notchHeight: 32, isPhysical: false
        ))
        let panel = NotchPanel(screen: screen, viewModel: model)
        defer { panel.close() }
        let outside = NSPoint(x: screen.frame.minX + 1, y: screen.frame.minY + 1)
        let reveal = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 1)
        panel.updatePointerInteraction(at: outside, mouseButtonPressed: false)
        XCTAssertTrue(model.isAutoHidden)
        XCTAssertTrue(panel.ignoresMouseEvents)
        panel.updatePointerInteraction(at: reveal, mouseButtonPressed: false)
        XCTAssertFalse(model.isAutoHidden)
        XCTAssertFalse(panel.ignoresMouseEvents)
        panel.updatePointerInteraction(at: outside, mouseButtonPressed: false)
        XCTAssertTrue(model.isAutoHidden)
        XCTAssertTrue(panel.ignoresMouseEvents)
        panel.setInteractionSuppressed(true)
        panel.updatePointerInteraction(at: reveal, mouseButtonPressed: false)
        XCTAssertTrue(model.isAutoHidden)
        XCTAssertTrue(model.isPresentationSuppressed)
        XCTAssertTrue(panel.ignoresMouseEvents)
        panel.setInteractionSuppressed(false)
        panel.updatePointerInteraction(at: reveal, mouseButtonPressed: false)
        XCTAssertFalse(model.isAutoHidden)
        XCTAssertFalse(model.isPresentationSuppressed)
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    @MainActor
    func testHUDCoversVisibleMenuBandWithoutVerticalGrowth() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            throw XCTSkip("Requires a physical notched display")
        }
        let settings = SettingsStore.shared
        let previousOffset = settings.notchHeightOffset
        settings.notchHeightOffset = 0
        defer { settings.notchHeightOffset = previousOffset }

        let geometry = NotchGeometry.forScreen(screen)
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        XCTAssertGreaterThanOrEqual(geometry.notchHeight, menuBarHeight)
        XCTAssertGreaterThanOrEqual(geometry.notchHeight, screen.safeAreaInsets.top)
        let model = NotchViewModel(geometry: geometry)
        let closedHeight = model.visualSize.height
        for kind in [HUDKind.volume, .brightness, .keyboardBacklight] {
            model.showHUD(kind, value: 0.5)
            XCTAssertEqual(model.visualSize.height, closedHeight)
            XCTAssertGreaterThan(model.visualSize.width, model.closedSize.width)
        }
        model.collapse()
    }

    @MainActor
    func testRenderedHUDBottomIsOpaqueAndOutlineStaysInsideBand() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No display in test host") }
        let settings = SettingsStore.shared
        let previousOutline = settings.contrastOutline
        defer { settings.contrastOutline = previousOutline }
        for scale: CGFloat in [1, 2] {
            for outline in [false, true] {
                settings.contrastOutline = outline
                for occlusion in [NotchOcclusion.visible, .fullscreen] {
                    for kind in [HUDKind.volume, .brightness] {
                        try autoreleasepool {
                            let model = NotchViewModel(geometry: .init(
                                notchWidth: 179, notchHeight: 33, isPhysical: true
                            ))
                            let panel = NotchPanel(screen: screen, viewModel: model)
                            defer { panel.close() }
                            panel.setOcclusion(occlusion, animated: false)
                            model.showHUD(kind, value: 0.89)
                            XCTAssertEqual(panel.alphaValue, 1)

                            let renderer = ImageRenderer(content: NotchRootView(viewModel: model)
                                .environment(\.displayScale, scale))
                            renderer.scale = scale
                            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                            let bottom = Int(model.visualSize.height * scale) - 1
                            let inset = model.topRadius + model.bottomRadius + 2
                            let left = Int(((NotchViewModel.panelSize.width - model.visualSize.width) / 2 + inset) * scale)
                            let right = bitmap.pixelsWide - left
                            for x in stride(from: left, to: right, by: 3) {
                                XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: bottom)).alphaComponent, 1, accuracy: 0.001)
                                XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: bottom + 1)).alphaComponent, 0, accuracy: 0.001)
                            }
                            model.collapse()
                            if occlusion == .fullscreen { XCTAssertEqual(panel.alphaValue, 0) }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testFullscreenRevealsOnlyHUDsAndKeepsThemPassive() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No display in test host") }
        let model = NotchViewModel(geometry: .init(
            notchWidth: 185, notchHeight: 32, isPhysical: false
        ))
        let panel = NotchPanel(screen: screen, viewModel: model)
        defer { panel.close() }
        panel.setOcclusion(.fullscreen, animated: false)
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertTrue(model.isPresentationSuppressed)

        for kind in [HUDKind.volume, .brightness, .keyboardBacklight] {
            model.showHUD(kind, value: 0.5)
            XCTAssertEqual(panel.alphaValue, 1)
            XCTAssertFalse(model.isPresentationSuppressed)
            XCTAssertEqual(model.visualSize.height, 32)
            panel.updatePointerInteraction(
                at: NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 1),
                mouseButtonPressed: false
            )
            XCTAssertTrue(panel.ignoresMouseEvents)
            XCTAssertFalse(model.isHovering)

            for blocked in [NotchOcclusion.missionControl, .gaming] {
                panel.setOcclusion(blocked, animated: false)
                XCTAssertEqual(panel.alphaValue, 0)
                XCTAssertTrue(model.isPresentationSuppressed)
                panel.setOcclusion(.fullscreen, animated: false)
                XCTAssertEqual(panel.alphaValue, 1)
            }
            model.collapse()
            XCTAssertEqual(panel.alphaValue, 0)
        }

        model.showPop(.accessibility)
        XCTAssertEqual(panel.alphaValue, 0)
        model.selectTab(.media)
        XCTAssertEqual(panel.alphaValue, 0)
        model.collapse()
        panel.setOcclusion(.visible, animated: false)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertFalse(model.isPresentationSuppressed)
    }

    @MainActor
    func testFullscreenHUDExtendsItsDeadlineAndHidesOnExpiry() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No display in test host") }
        let settings = SettingsStore.shared
        let duration = settings.soundHUDDuration
        settings.soundHUDDuration = 0.5
        defer { settings.soundHUDDuration = duration }
        let model = NotchViewModel(geometry: .init(
            notchWidth: 185, notchHeight: 32, isPhysical: true
        ))
        let panel = NotchPanel(screen: screen, viewModel: model)
        defer { panel.close() }
        panel.setOcclusion(.fullscreen, animated: false)
        model.showHUD(.volume, value: 0.5)
        try await Task.sleep(for: .milliseconds(300))
        model.showHUD(.volume, value: 0.75)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.status, .hud(.volume))
        XCTAssertEqual(panel.alphaValue, 1)
        // A sleep resumption does not guarantee that the main-actor dismissal
        // task has run first, particularly on instrumented CI runners.
        let expiryTimeout = ContinuousClock.now.advanced(by: .seconds(3))
        while model.status != .closed, ContinuousClock.now < expiryTimeout {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.status, .closed)
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    @MainActor
    func testFullscreenHUDSurvivesAnInFlightOcclusionFade() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("No display in test host") }
        let model = NotchViewModel(geometry: .init(
            notchWidth: 185, notchHeight: 32, isPhysical: true
        ))
        let panel = NotchPanel(screen: screen, viewModel: model)
        defer { panel.close() }
        panel.orderFrontRegardless()
        panel.setOcclusion(.fullscreen)
        try await Task.sleep(for: .milliseconds(30))
        model.showHUD(.volume, value: 0.5)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(panel.alphaValue, 1)
        model.collapse()
        XCTAssertEqual(panel.alphaValue, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(panel.alphaValue, 0)
    }

    @MainActor
    func testAutoHidePreferencePersistsWithoutDisplayRebuild() {
        let suite = "MNotchTests.AutoHide." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.autoHideSimulatedNotch)
        var rebuilds = 0
        settings.onDisplayConfigChanged = { rebuilds += 1 }
        settings.autoHideSimulatedNotch = true
        XCTAssertTrue(SettingsStore(defaults: defaults).autoHideSimulatedNotch)
        settings.autoHideSimulatedNotch = false
        XCTAssertFalse(SettingsStore(defaults: defaults).autoHideSimulatedNotch)
        XCTAssertEqual(rebuilds, 0)
    }

    @MainActor
    func testPowerObserverStaysSingleWhenNativeSourceFails() async {
        var attempts = 0
        let power = PowerSourceService(createNotificationSource: { _, _ in
            attempts += 1
            return nil
        })
        var events = 0
        power.onPowerEvent = { _ in events += 1 }
        for _ in 0..<100 { power.start() }
        XCTAssertEqual(attempts, 1)
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        // The notification queues a main-actor delivery; stop/restart must
        // prevent that old generation from emitting into the fresh session.
        power.stop()
        power.start()
        await Task.yield()
        XCTAssertEqual(events, 0)
        XCTAssertEqual(attempts, 2)
        power.stop()
    }

    func testUpdaterIsDisabledForTestsAndRequiresDebugOptIn() {
        XCTAssertFalse(AppUpdateRuntimePolicy(
            isRunningTests: true,
            isDebugBuild: false,
            environment: [:]
        ).updatesAreEnabled)
        XCTAssertFalse(AppUpdateRuntimePolicy(
            isRunningTests: false,
            isDebugBuild: true,
            environment: [:]
        ).updatesAreEnabled)
        XCTAssertTrue(AppUpdateRuntimePolicy(
            isRunningTests: false,
            isDebugBuild: true,
            environment: ["MNOTCH_ENABLE_UPDATES": "1"]
        ).updatesAreEnabled)
        XCTAssertTrue(AppUpdateRuntimePolicy(
            isRunningTests: false,
            isDebugBuild: false,
            environment: [:]
        ).updatesAreEnabled)
    }

    func testUpdaterOnlyAcceptsWritableApplicationsInstallations() {
        XCTAssertTrue(AppUpdateRuntimePolicy.installationIsEligible(
            bundleURL: URL(fileURLWithPath: "/Applications/MNotch.app"),
            applicationsDirectoryIsWritable: true
        ))
        XCTAssertFalse(AppUpdateRuntimePolicy.installationIsEligible(
            bundleURL: URL(fileURLWithPath: "/Volumes/MNotch/MNotch.app"),
            applicationsDirectoryIsWritable: true
        ))
        XCTAssertFalse(AppUpdateRuntimePolicy.installationIsEligible(
            bundleURL: URL(fileURLWithPath: "/Applications/MNotch"),
            applicationsDirectoryIsWritable: true
        ))
        XCTAssertFalse(AppUpdateRuntimePolicy.installationIsEligible(
            bundleURL: URL(
                fileURLWithPath: "/private/var/folders/AppTranslocation/MNotch.app"
            ),
            applicationsDirectoryIsWritable: true
        ))
        XCTAssertFalse(AppUpdateRuntimePolicy.installationIsEligible(
            bundleURL: URL(fileURLWithPath: "/Applications/MNotch.app"),
            applicationsDirectoryIsWritable: false
        ))
    }

    @MainActor
    func testSimulatedNotchExpansionLeavesRoomForTheFullTabStrip() {
        let geometry = NotchGeometry(
            notchWidth: NotchGeometry.fallbackWidth,
            notchHeight: NotchGeometry.fallbackHeight,
            isPhysical: false
        )

        XCTAssertEqual(
            NotchViewModel.expandedPanelWidth(for: geometry),
            NotchGeometry.fallbackWidth + 280
        )
    }

    func testPrivateLockSpaceIsOnlyUsedForTheEnabledFeatureWhileLocked() {
        XCTAssertFalse(LockPresentationPolicy.shouldElevateNotch(
            isLocked: true,
            featureEnabled: false
        ))
        XCTAssertFalse(LockPresentationPolicy.shouldElevateNotch(
            isLocked: false,
            featureEnabled: true
        ))
        XCTAssertTrue(LockPresentationPolicy.shouldElevateNotch(
            isLocked: true,
            featureEnabled: true
        ))
    }

    func testEventTapSafetyLatchRequiresANewPermissionGrant() {
        var latch = KeyTapSafetyLatch()
        XCTAssertFalse(latch.blocksRestart)

        latch.recordInterruption()
        XCTAssertTrue(latch.blocksRestart)

        // Repeated lifecycle refreshes must not silently clear the latch.
        latch.recordInterruption()
        XCTAssertTrue(latch.blocksRestart)

        latch.recordNewPermissionGrant()
        XCTAssertFalse(latch.blocksRestart)
    }

    func testAccessibilityRequirementFollowsEnabledKeyHUDs() {
        XCTAssertTrue(AccessibilityRequirement.isRequired(
            granted: false,
            soundHUDEnabled: true,
            displayHUDEnabled: false
        ))
        XCTAssertTrue(AccessibilityRequirement.isRequired(
            granted: false,
            soundHUDEnabled: false,
            displayHUDEnabled: true
        ))
        XCTAssertFalse(AccessibilityRequirement.isRequired(
            granted: true,
            soundHUDEnabled: true,
            displayHUDEnabled: true
        ))
        XCTAssertFalse(AccessibilityRequirement.isRequired(
            granted: false,
            soundHUDEnabled: false,
            displayHUDEnabled: false
        ))
    }

    @MainActor
    func testAccessibilityNoticeDismissesImmediatelyAfterGrant() {
        let viewModel = NotchViewModel(geometry: NotchGeometry(
            notchWidth: 185,
            notchHeight: 32,
            isPhysical: false
        ))
        viewModel.showPop(.accessibility)
        XCTAssertEqual(viewModel.status, .pop(.accessibility))

        viewModel.dismissAccessibilityNotice()
        XCTAssertEqual(viewModel.status, .closed)
    }

    @MainActor
    func testFeatureDemandStartsOnlyRequestedServices() {
        let demand = FeatureDemand(flags: FeatureFlags(
            mediaEnabled: true,
            hideInFullscreen: true,
            mediaHideWhileSourceActive: true
        ))

        XCTAssertTrue(demand.media)
        XCTAssertTrue(demand.audio)
        XCTAssertTrue(demand.occlusion)
        XCTAssertFalse(demand.displayControls)
        XCTAssertTrue(demand.keys)
        XCTAssertFalse(demand.power)
        XCTAssertFalse(demand.calendar)
        XCTAssertFalse(demand.agents)
    }

    @MainActor
    func testLockWidgetsContributeSharedServiceDemand() {
        let demand = FeatureDemand(flags: FeatureFlags(
            lockEnabled: true,
            lockNowPlaying: true,
            lockShowVolume: true,
            lockWidgetBattery: true,
            lockWidgetConnectivity: true,
            lockWidgetCalendar: true,
            lockWidgetFocus: true
        ))

        XCTAssertTrue(demand.media)
        XCTAssertTrue(demand.audio)
        XCTAssertTrue(demand.power)
        XCTAssertTrue(demand.bluetooth)
        XCTAssertTrue(demand.calendar)
        XCTAssertTrue(demand.focus)
    }

    @MainActor
    func testScreenSleepSuspendsPollingButKeepsEventDrivenServices() {
        let active = FeatureDemand(flags: FeatureFlags(
            mediaEnabled: true,
            soundHUDEnabled: true,
            displayHUDEnabled: true,
            batteryEnabled: true,
            connectivityEnabled: true,
            calendarEnabled: true,
            hideInFullscreen: true,
            focusEnabled: true,
            agentEnabled: true
        ))
        XCTAssertTrue(active.occlusion)
        XCTAssertTrue(active.quota)
        let sleeping = active.suspended(true)

        // High-frequency pollers pause while the display sleeps.
        XCTAssertFalse(sleeping.media)
        XCTAssertFalse(sleeping.audio)
        XCTAssertFalse(sleeping.displayControls)
        XCTAssertFalse(sleeping.keys)
        XCTAssertFalse(sleeping.calendar)
        XCTAssertFalse(sleeping.focus)
        // Event-driven services stay up.
        XCTAssertTrue(sleeping.power)
        XCTAssertTrue(sleeping.bluetooth)
        XCTAssertTrue(sleeping.agents)
        // Occlusion and quota stay up too: stopping them churns on every wake
        // (occlusion un-hides → notch flash; quota relaunches the CLI/codex),
        // and both poll cheaply, so suspending them would cost more than it saves.
        XCTAssertTrue(sleeping.occlusion)
        XCTAssertTrue(sleeping.quota)
    }

    @MainActor
    func testClaudeStatusLineMigrationRestoresCompletePreviousConfiguration() throws {
        let root: [String: Any] = [
            "theme": "dark",
            "statusLine": [
                "type": "command",
                "command": "/usr/bin/perl '/tmp/mnotch-claude-statusline.pl'",
                "padding": 4,
            ],
        ]
        let previous: [String: Any] = [
            "type": "command",
            "command": "/usr/local/bin/my-status",
            "padding": 7,
            "refreshInterval": 1_500,
        ]
        let backup = try JSONSerialization.data(withJSONObject: previous)

        let migrated = ClaudeHookInstaller.restoringRetiredQuotaBridge(
            in: root,
            backupData: backup,
            legacyCommand: "/usr/bin/perl '/tmp/mnotch-claude-statusline.pl'"
        )

        XCTAssertTrue(migrated.restored)
        XCTAssertEqual(migrated.root["theme"] as? String, "dark")
        let statusLine = try XCTUnwrap(migrated.root["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "/usr/local/bin/my-status")
        XCTAssertEqual(statusLine["padding"] as? Int, 7)
        XCTAssertEqual(statusLine["refreshInterval"] as? Int, 1_500)
    }

    @MainActor
    func testExpandedTabHeightIsBoundedPerContentType() {
        XCTAssertEqual(NotchViewModel.clampedExpandedHeight(20, for: .shelf), 124)
        XCTAssertEqual(NotchViewModel.clampedExpandedHeight(500, for: .calendar), 310)
        XCTAssertEqual(NotchViewModel.clampedExpandedHeight(201, for: .media), 201)
    }

    func testDisablingEveryCalendarProducesNoEnabledSource() {
        let available = ["work", "personal"]
        let enabled = CalendarSourceSelection.enabledIdentifiers(
            available: available,
            disabled: available
        )
        XCTAssertTrue(enabled.isEmpty)
    }

    func testCalendarSelectionPreservesAvailableOrder() {
        XCTAssertEqual(
            CalendarSourceSelection.enabledIdentifiers(
                available: ["work", "personal", "birthdays"],
                disabled: ["personal"]
            ),
            ["work", "birthdays"]
        )
    }

    func testUnknownAgentDecisionFallsBackToAsk() {
        XCTAssertEqual(AgentDecision.normalized("unexpected"), .ask)
        XCTAssertEqual(AgentDecision.normalized("allow"), .allow)
        XCTAssertEqual(AgentDecision.normalized("deny"), .deny)
    }

    func testCodexPermissionResponseMatchesAllowDenySchema() throws {
        for decision in [AgentDecision.allow, .deny] {
            let data = try XCTUnwrap(AgentHookResponse.data(
                event: "PermissionRequest",
                decision: decision
            ))
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let output = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
            XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
            let payload = try XCTUnwrap(output["decision"] as? [String: Any])
            XCTAssertEqual(payload["behavior"] as? String, decision.rawValue)
        }
        XCTAssertNil(AgentHookResponse.data(event: "PermissionRequest", decision: .ask))
    }

    func testAppleScriptSessionIdentifierRejectsInjection() {
        XCTAssertEqual(
            AgentMonitorService.safeAppleScriptIdentifier("w0t0p0:ABC-123"),
            "w0t0p0:ABC-123"
        )
        XCTAssertNil(AgentMonitorService.safeAppleScriptIdentifier("x\" then do shell script"))
    }

    @MainActor
    func testGenericToolSummaryShowsArgsNotDuplicatedName() throws {
        let json = #"{"event":"PermissionRequest","tool_name":"DatabaseMigrate","tool_input":{"target":"users","direction":"up"}}"#
        let event = try JSONDecoder().decode(AgentEvent.self, from: try XCTUnwrap(json.data(using: .utf8)))
        let summary = AgentMonitorService.summarize(event)
        XCTAssertFalse(summary.contains("DatabaseMigrate"))   // header already shows the name
        XCTAssertTrue(summary.contains("target: users"))
        XCTAssertTrue(summary.contains("direction: up"))
    }

    @MainActor
    func testAskUserQuestionIsNotApprovableFromNotch() {
        // Interactive-UI tools must never surface as a notch Allow/Deny card.
        XCTAssertFalse(AgentMonitorService.canApproveFromNotch("AskUserQuestion"))
        XCTAssertTrue(AgentMonitorService.canApproveFromNotch("Edit"))
        XCTAssertTrue(AgentMonitorService.canApproveFromNotch("Bash"))
        XCTAssertTrue(AgentMonitorService.canApproveFromNotch(nil))
    }

    @MainActor
    func testTerminalBundleIDMapsKnownProgramsForFrontmostCheck() {
        XCTAssertEqual(AgentMonitorService.terminalBundleID("iTerm.app"), "com.googlecode.iterm2")
        XCTAssertEqual(AgentMonitorService.terminalBundleID("Apple_Terminal"), "com.apple.Terminal")
        XCTAssertEqual(AgentMonitorService.terminalBundleID("ghostty"), "com.mitchellh.ghostty")
        // Unknown or missing terminals can't be matched, so the notch is shown
        // rather than wrongly deferred to a terminal we can't identify.
        XCTAssertNil(AgentMonitorService.terminalBundleID("some-unknown-term"))
        XCTAssertNil(AgentMonitorService.terminalBundleID(nil))
    }

    func testDeferDecisionProducesNoPermissionOutput() {
        // Deferring to the terminal replies "ask"; for PermissionRequest that
        // means no output, so the agent falls back to its native prompt.
        XCTAssertNil(AgentHookResponse.data(event: "PermissionRequest", decision: .ask))
    }

    func testPomodoroPhaseMachineCyclesWorkBreaksAndLongBreak() {
        // Work → short break until the cycle target is met, then a long break,
        // and any break always returns to work.
        XCTAssertEqual(
            PomodoroService.nextPhase(after: .work, completedWorkSessions: 1, cyclesPerLongBreak: 4),
            .shortBreak
        )
        XCTAssertEqual(
            PomodoroService.nextPhase(after: .work, completedWorkSessions: 4, cyclesPerLongBreak: 4),
            .longBreak
        )
        XCTAssertEqual(
            PomodoroService.nextPhase(after: .shortBreak, completedWorkSessions: 2, cyclesPerLongBreak: 4),
            .work
        )
        XCTAssertEqual(
            PomodoroService.nextPhase(after: .longBreak, completedWorkSessions: 4, cyclesPerLongBreak: 4),
            .work
        )
    }

    @MainActor
    func testPomodoroStartPauseKeepsRemainingAndStaysInert() {
        let pomodoro = PomodoroService()
        // Inert before start: no live activity, nothing running.
        XCTAssertFalse(pomodoro.isActive)
        XCTAssertFalse(pomodoro.isRunning)

        pomodoro.start()
        XCTAssertTrue(pomodoro.isRunning)
        XCTAssertGreaterThan(pomodoro.remaining, 0)

        pomodoro.pause()
        XCTAssertFalse(pomodoro.isRunning)
        XCTAssertTrue(pomodoro.isActive)          // paused still shows the wing
        let frozen = pomodoro.remaining
        XCTAssertGreaterThan(frozen, 0)

        pomodoro.reset()
        XCTAssertFalse(pomodoro.isActive)
        XCTAssertEqual(pomodoro.phase, .work)
    }

    @MainActor
    func testExternallyEndedRequestClearsTheStuckCardAndCollapses() throws {
        // Reproduces the "approve in Claude, notch card hangs open" bug: when
        // the relay times out (or the session dies) the server ends the pending
        // request out-of-band, and the notch card must clear instead of hanging
        // until the app is relaunched.
        let monitor = AgentMonitorService()
        var resolvedCount = 0
        monitor.onRequestResolved = { resolvedCount += 1 }

        let json = #"{"event":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        let event = try JSONDecoder().decode(AgentEvent.self, from: try XCTUnwrap(json.data(using: .utf8)))
        monitor.handle(event, requestID: 7)
        XCTAssertTrue(monitor.hasPendingRequest)

        // An unrelated id must not disturb the live request.
        monitor.requestEndedExternally(999)
        XCTAssertTrue(monitor.hasPendingRequest)
        XCTAssertEqual(resolvedCount, 0)

        // The real request ending externally clears the card, drops back to
        // waiting (the agent is now blocked on its own terminal prompt), and
        // asks the notch to collapse.
        monitor.requestEndedExternally(7)
        XCTAssertFalse(monitor.hasPendingRequest)
        XCTAssertNil(monitor.firstPending)
        XCTAssertEqual(monitor.sessions.first?.status, .waiting)
        XCTAssertEqual(resolvedCount, 1)
    }

    func testClaudeCLIUsageParsesSessionAndWeeklyWindows() throws {
        let output = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 4% used · resets Jul 15 at 6:30pm (Asia/Saigon)
        Current week (all models): 74% used · resets Jul 17 at 8pm (Asia/Saigon)
        Current week (Fable): 57% used · resets Jul 17 at 8pm (Asia/Saigon)

        What's contributing to your limits usage?
        Last 24h · 540 requests · 3 sessions
        """
        let windows = try XCTUnwrap(ClaudeUsageClient.parse(output))
        XCTAssertEqual(windows.map(\.label), ["5h", "7d", "Fable"])
        XCTAssertEqual(windows.map(\.id), ["claude-session", "claude-week", "claude-week-Fable"])
        XCTAssertEqual(windows[0].usedPercent, 4)
        XCTAssertEqual(windows[1].usedPercent, 74)
        XCTAssertEqual(windows[2].usedPercent, 57)
        XCTAssertEqual(windows[0].durationMinutes, 300)
        XCTAssertEqual(windows[1].durationMinutes, 10_080)
        XCTAssertNotNil(windows[0].resetsAt)
    }

    func testClaudeCLIUsageIgnoresProseAndReturnsNilWhenNoBars() {
        let output = """
        Approximate, based on local sessions on this machine.
        66% of your usage came from subagent-heavy sessions
        Top subagents: workflow-subagent 11%
        """
        XCTAssertNil(ClaudeUsageClient.parse(output))
    }

    func testClaudeCLIResetDateParsesDatedForm() {
        let date = ClaudeUsageClient.parseCLIDate("resets Jul 17 at 8pm (Asia/Saigon)")
        XCTAssertNotNil(date)
    }

    func testClaudeCLIUsageParsesLineWithLongTimezoneAndOverage() throws {
        // A long IANA timezone at 100% used pushes the line past 90 chars; it
        // must still parse (the old guard dropped it).
        let output = """
        Current week (all models): 100% used · resets Dec 31 at 11:59pm (America/Argentina/Buenos_Aires)
        """
        let windows = try XCTUnwrap(ClaudeUsageClient.parse(output))
        XCTAssertEqual(windows.map(\.label), ["7d"])
        XCTAssertEqual(windows[0].usedPercent, 100)
    }

    func testCodexQuotaParserReadsOfficialWindowsAndCredits() throws {
        let json = #"{"id":2,"result":{"rateLimits":{"planType":"plus","credits":{"balance":"12.50"},"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1784044800},"secondary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":1784649600}},"rateLimitResetCredits":{"availableCount":2}}}"#
        let snapshot = try XCTUnwrap(CodexQuotaParser.snapshot(
            from: try XCTUnwrap(json.data(using: .utf8))
        ))
        XCTAssertEqual(snapshot.planType, "plus")
        XCTAssertEqual(snapshot.creditsBalance, "12.50")
        XCTAssertEqual(snapshot.resetCredits, 2)
        XCTAssertEqual(snapshot.primary?.label, "5h")
        XCTAssertEqual(snapshot.primary?.remainingPercent, 75)
        XCTAssertEqual(snapshot.secondary?.label, "7d")
        XCTAssertEqual(snapshot.secondary?.remainingPercent, 40)
    }

    func testCodexSparseUpdateKeepsWindowMetadata() throws {
        let initialJSON = #"{"id":2,"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1784044800}},"rateLimitResetCredits":{"availableCount":2}}}"#
        let updateJSON = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":31}}}}"#
        let initial = try XCTUnwrap(CodexQuotaParser.snapshot(
            from: try XCTUnwrap(initialJSON.data(using: .utf8))
        ))
        let update = try XCTUnwrap(CodexQuotaParser.snapshot(
            from: try XCTUnwrap(updateJSON.data(using: .utf8))
        ))
        let merged = update.merging(over: initial)

        XCTAssertEqual(merged.primary?.label, "5h")
        XCTAssertEqual(merged.primary?.durationMinutes, 300)
        XCTAssertEqual(merged.primary?.resetsAt, initial.primary?.resetsAt)
        XCTAssertEqual(merged.primary?.usedPercent, 31)
        XCTAssertEqual(merged.planType, "plus")
        XCTAssertEqual(merged.resetCredits, 2)
    }

    func testCodexIndividualBudgetIsUsedWhenRollingWindowsAreAbsent() throws {
        let json = #"{"id":2,"result":{"rateLimits":{"planType":"business","individualLimit":{"limit":"100","used":"58","remainingPercent":42,"resetsAt":1784649600}}}}"#
        let snapshot = try XCTUnwrap(CodexQuotaParser.snapshot(
            from: try XCTUnwrap(json.data(using: .utf8))
        ))

        XCTAssertEqual(snapshot.primary?.label, "Budget")
        XCTAssertEqual(snapshot.primary?.remainingPercent, 42)
        XCTAssertEqual(snapshot.primary?.resetsAt?.timeIntervalSince1970, 1_784_649_600)
    }

    func testRemainingQuotaClampsAndInvertsUsedPercentage() {
        XCTAssertEqual(
            QuotaWindow(id: "5h", label: "5h", usedPercent: 21.5,
                        durationMinutes: 300, resetsAt: nil).remainingPercent,
            78.5
        )
        XCTAssertEqual(
            QuotaWindow(id: "high", label: "5h", usedPercent: 140,
                        durationMinutes: 300, resetsAt: nil).remainingPercent,
            0
        )
    }

    func testDiffEngineTracksReplacementAndLineNumbers() {
        let result = DiffEngine.rows(old: "one\ntwo\nthree", new: "one\nTWO\nthree")
        XCTAssertEqual(result.adds, 1)
        XCTAssertEqual(result.dels, 1)
        XCTAssertEqual(result.rows.map(\.kind), [.equal, .remove, .add, .equal])
        XCTAssertEqual(result.rows.map(\.oldNo), [1, 2, nil, 3])
        XCTAssertEqual(result.rows.map(\.newNo), [1, nil, 2, 3])
        XCTAssertEqual(result.rows.map(\.id), [0, 1, 2, 3])
    }

    func testDiffEngineUsesBoundedFallbackForLargeInput() {
        let old = Array(repeating: "old", count: 201).joined(separator: "\n")
        let new = Array(repeating: "new", count: 201).joined(separator: "\n")
        let result = DiffEngine.rows(old: old, new: new)
        XCTAssertEqual(result.dels, 201)
        XCTAssertEqual(result.adds, 201)
        XCTAssertEqual(result.rows.count, 402)
    }

    func testIdleResolverDegradesDuoToAvailableContent() {
        XCTAssertEqual(
            NotchIdleResolver.resolve(.init(
                activity: .duo,
                mostRecent: false,
                mediaAvailable: true,
                calendarAvailable: false,
                dismissed: false
            )),
            .playing
        )
    }

    func testIdleResolverHonorsDismissalAndMostRecent() {
        XCTAssertEqual(
            NotchIdleResolver.resolve(.init(
                activity: .calendar,
                mostRecent: true,
                mediaAvailable: true,
                calendarAvailable: true,
                dismissed: false
            )),
            .playing
        )
        XCTAssertEqual(
            NotchIdleResolver.resolve(.init(
                activity: .duo,
                mostRecent: false,
                mediaAvailable: true,
                calendarAvailable: true,
                dismissed: true
            )),
            .empty
        )
    }

    @MainActor
    func testCodexHookInstallerPreservesOtherHandlers() throws {
        let root: [String: Any] = [
            "custom": "keep",
            "hooks": [
                "PermissionRequest": [[
                    "matcher": "Bash",
                    "hooks": [["type": "command", "command": "other-hook"]],
                ]],
            ],
        ]
        let installed = CodexHookInstaller.installing(
            into: root,
            command: "/usr/bin/perl '/tmp/mnotch-relay.pl' codex"
        )
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: installed))
        let hooks = try XCTUnwrap(installed["hooks"] as? [String: Any])
        for event in ["PermissionRequest", "SessionStart", "Stop"] {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertTrue(groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains { handler in
                    (handler["command"] as? String)?.contains("mnotch-relay.pl") == true
                } == true
            })
        }

        let removed = CodexHookInstaller.uninstalling(from: installed,
            command: "/usr/bin/perl '/tmp/mnotch-relay.pl' codex")
        XCTAssertEqual(removed["custom"] as? String, "keep")
        let remainingHooks = try XCTUnwrap(removed["hooks"] as? [String: Any])
        let permissionGroups = try XCTUnwrap(
            remainingHooks["PermissionRequest"] as? [[String: Any]]
        )
        XCTAssertEqual(
            (permissionGroups.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String,
            "other-hook"
        )
        XCTAssertNil(remainingHooks["SessionStart"])
        XCTAssertNil(remainingHooks["Stop"])
    }

    @MainActor
    func testCodexPermissionPayloadDecodesPatchAndLastMessage() throws {
        let json = #"{"event":"PermissionRequest","session_id":"codex-1","cwd":"/tmp/project","tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** End Patch"},"last_assistant_message":"Review this change","agent_kind":"codex"}"#
        let event = try JSONDecoder().decode(
            AgentEvent.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )
        XCTAssertEqual(event.lastMessage, "Review this change")
        XCTAssertEqual(
            AgentMonitorService.detail(event),
            .patch(patch: "*** Begin Patch\n*** End Patch")
        )
    }
}

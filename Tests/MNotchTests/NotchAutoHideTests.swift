import AppKit
import XCTest
@testable import MNotch

@MainActor
final class NotchAutoHideTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let model: NotchViewModel
        let panel: NotchPanel
        let start = ContinuousClock.now
        private let previous: (autoHide: Bool, hover: Bool, haptic: Bool)

        init(physical: Bool = false) throws {
            _ = NSApplication.shared
            guard let screen = NSScreen.screens.first else { throw XCTSkip("No display in test host") }
            let settings = SettingsStore.shared
            previous = (settings.autoHideSimulatedNotch, settings.expandOnHover, settings.hapticFeedback)
            settings.autoHideSimulatedNotch = true
            settings.expandOnHover = false
            settings.hapticFeedback = false
            model = NotchViewModel(geometry: .init(
                notchWidth: 185, notchHeight: 32, isPhysical: physical
            ))
            panel = NotchPanel(screen: screen, viewModel: model)
        }

        var edge: NSPoint { NSPoint(x: panel.frame.midX, y: panel.frame.maxY) }
        var body: NSPoint { NSPoint(x: edge.x, y: edge.y - 16) }
        var outside: NSPoint { NSPoint(x: panel.frame.minX + 1, y: panel.frame.minY + 1) }

        func sample(_ point: NSPoint, at milliseconds: Int, pressed: Bool = false) {
            panel.updatePointerInteraction(
                at: point, mouseButtonPressed: pressed,
                now: start + .milliseconds(milliseconds)
            )
        }

        func close() {
            panel.close()
            let settings = SettingsStore.shared
            settings.autoHideSimulatedNotch = previous.autoHide
            settings.expandOnHover = previous.hover
            settings.hapticFeedback = previous.haptic
        }
    }

    func testHiddenNotchNeverOwnsMenuBarClicksOutsideTheTwoPointStrip() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let hosting = try XCTUnwrap(fixture.panel.contentView as? NotchHostingView)
        var elapsed = 0
        // Cover the body, both wings and the old 8pt hover apron. Even an
        // arbitrarily long hover must leave the underlying menu bar reachable.
        for depth: CGFloat in [2, 3, 8, 16, 24, 32, 39] {
            for x: CGFloat in [-180, -90, 0, 90, 180] {
                let point = NSPoint(x: fixture.edge.x + x, y: fixture.edge.y - depth)
                fixture.sample(point, at: elapsed)
                fixture.sample(point, at: elapsed + 1000)
                fixture.sample(point, at: elapsed + 1001, pressed: true)
                XCTAssertTrue(fixture.model.isAutoHidden, "depth=\(depth), x=\(x)")
                XCTAssertTrue(fixture.panel.ignoresMouseEvents)
                XCTAssertFalse(hosting.containsInteractivePoint(point))
                XCTAssertFalse(hosting.containsAutoHideRevealPoint(point))
                elapsed += 2000
            }
        }
        XCTAssertEqual(fixture.model.interactiveRect(in: hosting.bounds, flipped: hosting.isFlipped), .zero)
        XCTAssertNil(hosting.hitTest(NSPoint(x: hosting.bounds.midX, y: hosting.bounds.maxY - 16)))
    }

    func testExactTopEdgeRequiresTwoHundredMillisecondsAndPassesClicksUntilThen() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let hosting = try XCTUnwrap(fixture.panel.contentView as? NotchHostingView)
        XCTAssertTrue(hosting.containsAutoHideRevealPoint(fixture.edge))
        XCTAssertTrue(hosting.containsAutoHideRevealPoint(NSPoint(x: fixture.edge.x, y: fixture.edge.y - 1.99)))
        XCTAssertFalse(hosting.containsAutoHideRevealPoint(NSPoint(x: fixture.edge.x, y: fixture.edge.y + 0.01)))
        fixture.sample(fixture.edge, at: 0)
        fixture.sample(fixture.edge, at: 199)
        XCTAssertTrue(fixture.model.isAutoHidden)
        XCTAssertFalse(fixture.model.isHovering)
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
        fixture.sample(fixture.edge, at: 200)
        XCTAssertFalse(fixture.model.isAutoHidden)
        XCTAssertTrue(fixture.model.isHovering)
        XCTAssertFalse(fixture.panel.ignoresMouseEvents)
        XCTAssertEqual(fixture.model.status, .closed)
        // Move down to controls without keeping the pointer on the edge.
        fixture.sample(fixture.body, at: 1000)
        XCTAssertFalse(fixture.model.isAutoHidden)
        XCTAssertFalse(fixture.panel.ignoresMouseEvents)
    }

    func testLeavingTheEdgeCancelsRatherThanAccumulatesDwell() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.sample(fixture.edge, at: 0)
        fixture.sample(fixture.edge, at: 199)
        fixture.sample(fixture.body, at: 200)
        fixture.sample(fixture.edge, at: 201)
        fixture.sample(fixture.edge, at: 400)
        XCTAssertTrue(fixture.model.isAutoHidden)
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
        fixture.sample(fixture.edge, at: 401)
        XCTAssertFalse(fixture.model.isAutoHidden)
    }

    func testMenuBarClickCancelsDwellUntilPointerLeavesAndReenters() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.sample(fixture.edge, at: 0)
        fixture.sample(fixture.edge, at: 180, pressed: true)
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
        fixture.sample(fixture.edge, at: 181)
        fixture.sample(fixture.edge, at: 2000)
        XCTAssertTrue(fixture.model.isAutoHidden)
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
        fixture.sample(fixture.body, at: 2001)
        fixture.sample(fixture.edge, at: 2002)
        fixture.sample(fixture.edge, at: 2201)
        XCTAssertTrue(fixture.model.isAutoHidden)
        fixture.sample(fixture.edge, at: 2202)
        XCTAssertFalse(fixture.model.isAutoHidden)
    }

    func testExitWaitsThreeHundredMillisecondsAndReentryCancelsHiding() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.sample(fixture.edge, at: 0)
        fixture.sample(fixture.edge, at: 200)
        fixture.sample(fixture.outside, at: 201)
        // Click routing is released immediately even during the hide grace.
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
        fixture.sample(fixture.outside, at: 500)
        XCTAssertFalse(fixture.model.isAutoHidden)
        fixture.sample(fixture.body, at: 501)
        XCTAssertFalse(fixture.panel.ignoresMouseEvents)
        fixture.sample(fixture.body, at: 1000)
        XCTAssertFalse(fixture.model.isAutoHidden)
        fixture.sample(fixture.outside, at: 1001)
        fixture.sample(fixture.outside, at: 1300)
        XCTAssertFalse(fixture.model.isAutoHidden)
        fixture.sample(fixture.outside, at: 1301)
        XCTAssertTrue(fixture.model.isAutoHidden)
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
        fixture.sample(fixture.body, at: 2000)
        XCTAssertTrue(fixture.model.isAutoHidden)
    }

    func testRevealStripIsStableAcrossIdleWingsAndCoordinateSystems() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let bounds = CGRect(x: 10, y: 20, width: 700, height: 448)
        let flipped = fixture.model.autoHideRevealRect(in: bounds, flipped: true)
        let unflipped = fixture.model.autoHideRevealRect(in: bounds, flipped: false)
        XCTAssertEqual(flipped, CGRect(x: bounds.midX - 92.5, y: bounds.minY, width: 185, height: 2))
        XCTAssertEqual(unflipped, CGRect(x: bounds.midX - 92.5, y: bounds.maxY - 2, width: 185, height: 2))
        fixture.model.mediaActive = true
        fixture.model.pomodoroActive = true
        fixture.model.setPointerInside(true)
        XCTAssertEqual(fixture.model.autoHideRevealRect(in: bounds, flipped: true), flipped)
        let wing = NSPoint(x: fixture.edge.x + 100, y: fixture.edge.y - 1)
        fixture.sample(wing, at: 0)
        fixture.sample(wing, at: 1000)
        XCTAssertTrue(fixture.model.isAutoHidden)
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
    }

    func testEachPanelUsesItsOwnTopEdgeAndDwell() throws {
        let first = try Fixture()
        defer { first.close() }
        let second = try Fixture()
        defer { second.close() }
        // Simulate a display left of and below the primary one.
        second.panel.setFrame(first.panel.frame.offsetBy(dx: -1000, dy: -600), display: false)
        first.sample(first.edge, at: 0)
        second.sample(first.edge, at: 0)
        first.sample(first.edge, at: 200)
        second.sample(first.edge, at: 1000)
        XCTAssertFalse(first.model.isAutoHidden)
        XCTAssertTrue(second.model.isAutoHidden)
        second.sample(second.edge, at: 1001)
        second.sample(second.edge, at: 1200)
        XCTAssertTrue(second.model.isAutoHidden)
        second.sample(second.edge, at: 1201)
        XCTAssertFalse(second.model.isAutoHidden)
    }

    func testTransientHUDAndNotificationHoverDoNotRevealTheClosedNotch() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.model.showHUD(.volume, value: 0.5)
        fixture.sample(fixture.body, at: 0)
        XCTAssertFalse(fixture.model.isAutoHidden)
        XCTAssertTrue(fixture.model.isHovering)
        fixture.model.collapse()
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
        fixture.sample(fixture.body, at: 1)
        XCTAssertTrue(fixture.model.isAutoHidden)
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
        fixture.model.showPop(.accessibility)
        fixture.sample(fixture.edge, at: 2)
        fixture.sample(fixture.edge, at: 1000)
        XCTAssertFalse(fixture.model.isAutoHidden)
        fixture.model.dismissAccessibilityNotice()
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
        fixture.sample(fixture.edge, at: 1001)
        XCTAssertTrue(fixture.model.isAutoHidden)
        fixture.sample(fixture.edge, at: 1200)
        XCTAssertTrue(fixture.model.isAutoHidden)
        fixture.sample(fixture.edge, at: 1201)
        XCTAssertFalse(fixture.model.isAutoHidden)
        fixture.model.expand(.media)
        fixture.sample(fixture.outside, at: 1202)
        fixture.sample(fixture.outside, at: 2000)
        XCTAssertFalse(fixture.model.isAutoHidden)
        XCTAssertTrue(fixture.model.status.isExpanded)
    }

    func testSuppressionAndPreferenceChangesDiscardPendingIntent() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.sample(fixture.edge, at: 0)
        fixture.panel.setInteractionSuppressed(true)
        fixture.sample(fixture.edge, at: 1000)
        fixture.panel.setInteractionSuppressed(false)
        fixture.sample(fixture.edge, at: 1001)
        fixture.sample(fixture.edge, at: 1200)
        XCTAssertTrue(fixture.model.isAutoHidden)
        fixture.sample(fixture.edge, at: 1201)
        XCTAssertFalse(fixture.model.isAutoHidden)
        SettingsStore.shared.autoHideSimulatedNotch = false
        fixture.sample(fixture.body, at: 1300)
        XCTAssertFalse(fixture.model.isAutoHideRevealed)
        XCTAssertFalse(fixture.model.isAutoHidden)
        SettingsStore.shared.autoHideSimulatedNotch = true
        fixture.sample(fixture.body, at: 1400)
        XCTAssertTrue(fixture.model.isAutoHidden)
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
    }

    func testPhysicalNotchStillUsesNormalHoverWithoutAnEdgeDwell() throws {
        let fixture = try Fixture(physical: true)
        defer { fixture.close() }
        fixture.sample(fixture.body, at: 0)
        XCTAssertFalse(fixture.model.isAutoHidden)
        XCTAssertTrue(fixture.model.isHovering)
        XCTAssertFalse(fixture.panel.ignoresMouseEvents)
    }

    func testActiveControlDragRetainsEventsOutsideTheNotch() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.sample(fixture.edge, at: 0)
        fixture.sample(fixture.edge, at: 200)
        fixture.model.expand(.media)
        fixture.sample(fixture.body, at: 201, pressed: true)
        fixture.sample(fixture.outside, at: 202, pressed: true)
        fixture.sample(fixture.outside, at: 1000, pressed: true)
        XCTAssertFalse(fixture.panel.ignoresMouseEvents)
        XCTAssertFalse(fixture.model.isAutoHidden)
        fixture.sample(fixture.outside, at: 1001)
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
    }

    func testWindowServerRoutesHiddenNotchClicksToARealMenuBarIcon() async throws {
        guard ProcessInfo.processInfo.environment["MNOTCH_TEST_MENU_BAR_ROUTING"] == "1" else {
            throw XCTSkip("Set MNOTCH_TEST_MENU_BAR_ROUTING=1 on an interactive desktop")
        }
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        button.title = "◉"
        button.toolTip = "MNotch auto-hide routing test"
        try await Task.sleep(for: .milliseconds(100))
        let statusWindow = try XCTUnwrap(button.window)
        let iconFrame = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let icon = NSPoint(x: iconFrame.midX, y: iconFrame.midY)
        let edge = NSPoint(x: icon.x, y: iconFrame.maxY - 1)
        let iconTarget = NSWindow.windowNumber(at: icon, belowWindowWithWindowNumber: 0)
        let edgeTarget = NSWindow.windowNumber(at: edge, belowWindowWithWindowNumber: 0)
        // Recent macOS versions host status items in a remote menu-bar
        // window; button.window can have a proxy ID instead of its CGWindowID.
        XCTAssertGreaterThan(iconTarget, 0)
        XCTAssertEqual(edgeTarget, iconTarget)

        // Put the real notch panel directly over this temporary status item.
        // WindowServer's hit target proves pass-through across window/process
        // boundaries; a view-level hitTest(nil) alone would not prove it.
        fixture.panel.setFrame(NSRect(
            x: icon.x - fixture.panel.frame.width / 2,
            y: iconFrame.maxY - fixture.panel.frame.height,
            width: fixture.panel.frame.width,
            height: fixture.panel.frame.height
        ), display: false)
        fixture.panel.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(30))
        fixture.sample(icon, at: 0)
        fixture.sample(icon, at: 1000)
        XCTAssertEqual(NSWindow.windowNumber(at: icon, belowWindowWithWindowNumber: 0), iconTarget)
        fixture.sample(edge, at: 1001)
        fixture.sample(edge, at: 1200)
        XCTAssertTrue(fixture.model.isAutoHidden)
        XCTAssertEqual(NSWindow.windowNumber(at: edge, belowWindowWithWindowNumber: 0), edgeTarget)
        fixture.sample(edge, at: 1201, pressed: true)
        fixture.sample(edge, at: 2000)
        XCTAssertTrue(fixture.model.isAutoHidden)
        XCTAssertEqual(NSWindow.windowNumber(at: icon, belowWindowWithWindowNumber: 0), iconTarget)

        fixture.sample(icon, at: 2001)
        fixture.sample(edge, at: 2002)
        fixture.sample(edge, at: 2202)
        XCTAssertFalse(fixture.model.isAutoHidden)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(NSWindow.windowNumber(at: icon, belowWindowWithWindowNumber: 0), fixture.panel.windowNumber,
                       "The same test must detect that a deliberately revealed notch owns its controls")
        fixture.sample(fixture.outside, at: 2203)
        fixture.sample(fixture.outside, at: 2503)
        XCTAssertTrue(fixture.model.isAutoHidden)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(NSWindow.windowNumber(at: icon, belowWindowWithWindowNumber: 0), iconTarget)
    }
}

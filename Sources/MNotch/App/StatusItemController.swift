import AppKit
import Observation

/// Menu bar status item: the logo as a template silhouette (adapts to menu
/// bar light/dark), with a small menu — the only Quit UI in an LSUIElement app.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var accessibilityItem: NSMenuItem?
    private var accessibilitySeparator: NSMenuItem?

    private struct AccessibilityState: Equatable {
        let granted: Bool
        let required: Bool
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self
        let accessibility = NSMenuItem(
            title: "",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibility.target = self
        menu.addItem(accessibility)
        let accessibilitySeparator = NSMenuItem.separator()
        menu.addItem(accessibilitySeparator)
        accessibilityItem = accessibility
        self.accessibilitySeparator = accessibilitySeparator

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        settings.image = Self.menuIcon("gearshape")
        menu.addItem(settings)
        let welcome = NSMenuItem(
            title: "Welcome…",
            action: #selector(showWelcome),
            keyEquivalent: ""
        )
        welcome.target = self
        welcome.image = Self.menuIcon("hand.wave")
        menu.addItem(welcome)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit MNotch",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        quit.image = Self.menuIcon("power")
        menu.addItem(quit)
        item.menu = menu

        statusItem = item
        observeAccessibilityState()
#if DEBUG
        mnotchLog.debug("status item installed visible=\(item.isVisible)")
#endif
    }

    /// Consistently-sized template SF Symbol for a menu item's leading icon.
    private static func menuIcon(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func showWelcome() {
        WelcomeWindowController.shared.show()
    }

    @objc private func openAccessibilitySettings() {
        AppServices.shared.accessibility.requestAccess()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Covers grants/revocations made externally even if MNotch never
        // received an activation transition before the menu was opened.
        AppServices.shared.accessibility.refresh()
    }

    /// Alcove-style framed glyph: a continuous rounded shell, a compact notch
    /// attached to its top edge, and the Maclife double-peak M below. Drawing
    /// it as a template keeps it crisp on Retina and lets macOS tint it for
    /// light/dark menu bars and pressed state.
    private func observeAccessibilityState() {
        let state = withObservationTracking {
            AccessibilityState(
                granted: AppServices.shared.accessibility.isGranted,
                required: AppServices.shared.accessibility.isRequiredForEnabledFeatures
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAccessibilityState() }
        }
        updateAccessibilityState(state)
    }

    private func updateAccessibilityState(_ state: AccessibilityState) {
        statusItem?.button?.image = Self.templateLogo(showWarning: state.required)
        if state.granted {
            statusItem?.button?.toolTip = "MNotch"
            accessibilityItem?.isHidden = true
            accessibilitySeparator?.isHidden = true
        } else if state.required {
            statusItem?.button?.toolTip = "MNotch — Accessibility required"
            accessibilityItem?.isHidden = false
            accessibilitySeparator?.isHidden = false
            accessibilityItem?.title = "Accessibility Required…"
            accessibilityItem?.image = Self.menuIcon("exclamationmark.triangle.fill")
        } else {
            statusItem?.button?.toolTip = "MNotch — Accessibility not granted"
            accessibilityItem?.isHidden = false
            accessibilitySeparator?.isHidden = false
            accessibilityItem?.title = "Accessibility: Not Granted…"
            accessibilityItem?.image = Self.menuIcon("accessibility")
        }
    }

    private static func templateLogo(showWarning: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            let display = NSBezierPath(
                roundedRect: NSRect(x: 1.8, y: 1.8, width: 14.4, height: 14.4),
                xRadius: 3.3,
                yRadius: 3.3
            )
            display.lineWidth = 1.0
            display.stroke()

            NSColor.black.setFill()

            // Notch centered on the top edge: ~5 wide, a touch taller.
            let notch = NSBezierPath()
            notch.move(to: NSPoint(x: 6.5, y: 16.2))
            notch.line(to: NSPoint(x: 11.5, y: 16.2))
            notch.line(to: NSPoint(x: 11.32, y: 15.05))
            notch.curve(
                to: NSPoint(x: 10.6, y: 14.5),
                controlPoint1: NSPoint(x: 11.22, y: 14.68),
                controlPoint2: NSPoint(x: 10.95, y: 14.5)
            )
            notch.line(to: NSPoint(x: 7.4, y: 14.5))
            notch.curve(
                to: NSPoint(x: 6.68, y: 15.05),
                controlPoint1: NSPoint(x: 7.05, y: 14.5),
                controlPoint2: NSPoint(x: 6.78, y: 14.68)
            )
            notch.close()
            notch.fill()

            // Maclife mountain range (favicon-ml.svg), dropped so its base sits
            // right on the frame's bottom edge — no hollow gap beneath it.
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                // SVG viewBox x∈[1.29,62.16], y∈[2.94,50.15] (top-down) → icon.
                NSPoint(
                    x: 3.25 + (x - 1.29) / 60.87 * 11.5,
                    y: 1.9 + (50.15 - y) / 47.21 * 11.3
                )
            }
            let mark = NSBezierPath()
            mark.move(to: p(13.77, 17.46))   // left peak
            mark.line(to: p(1.29, 50.15))
            mark.line(to: p(12.29, 50.15))
            mark.line(to: p(27.56, 26.78))
            mark.close()
            mark.move(to: p(43.12, 2.94))    // tall right peak
            mark.line(to: p(27.56, 26.78))
            mark.line(to: p(62.16, 50.15))
            mark.close()
            mark.move(to: p(27.56, 26.78))   // base fill
            mark.line(to: p(12.29, 50.15))
            mark.line(to: p(62.16, 50.15))
            mark.close()
            mark.fill()

            if showWarning {
                // Compact notification badge with a knocked-out exclamation;
                // it remains a template so macOS owns the menu-bar tint.
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 10.4, y: 0.2, width: 7.4, height: 7.4)).fill()
                NSGraphicsContext.current?.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(
                    roundedRect: NSRect(x: 13.55, y: 3.0, width: 1.05, height: 2.9),
                    xRadius: 0.5,
                    yRadius: 0.5
                ).fill()
                NSBezierPath(ovalIn: NSRect(x: 13.55, y: 1.45, width: 1.05, height: 1.05)).fill()
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

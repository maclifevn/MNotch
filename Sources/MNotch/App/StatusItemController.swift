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
        observeVisibility()
#if DEBUG
        mnotchLog.debug("status item installed visible=\(item.isVisible)")
#endif
    }

    /// Show/hide the menu bar item per Settings. Settings stays reachable from
    /// the notch's gear tab, and Quit lives in Settings too, so hiding it never
    /// traps the user.
    private func observeVisibility() {
        let hidden = withObservationTracking {
            SettingsStore.shared.hideMenuBarIcon
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeVisibility() }
        }
        statusItem?.isVisible = !hidden
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

    /// Menu-bar icon point size — matches the neighbouring status glyphs.
    private static let iconSize: CGFloat = 16

    /// The MNotch app-icon badge, rendered from Support/MNotch_icon.svg into
    /// Support/menubar-icon.png at build time and shipped in Resources. Loaded
    /// once and marked template so macOS tints it for the menu bar.
    private static let baseIcon: NSImage = {
        let image: NSImage
        if let url = Bundle.main.url(forResource: "menubar-icon", withExtension: "png"),
           let loaded = NSImage(contentsOf: url) {
            image = loaded
        } else {
            image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        }
        image.size = NSSize(width: iconSize, height: iconSize)
        image.isTemplate = true
        return image
    }()

    /// Base badge, plus a knocked-out warning dot when Accessibility is needed.
    /// Composited at 18pt (where the badge coords are tuned) then sized down.
    private static func templateLogo(showWarning: Bool) -> NSImage {
        guard showWarning else { return baseIcon }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            baseIcon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
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
            return true
        }
        image.size = NSSize(width: iconSize, height: iconSize)
        image.isTemplate = true
        return image
    }
}

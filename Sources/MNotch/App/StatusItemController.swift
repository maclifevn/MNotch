import AppKit

/// Menu bar status item: the logo as a template silhouette (adapts to menu
/// bar light/dark), with a small menu — the only Quit UI in an LSUIElement app.
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.templateLogo()
        item.button?.toolTip = "MNotch"

        let menu = NSMenu()
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit MNotch",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        item.menu = menu

        statusItem = item
        mnotchLog.notice("status item installed visible=\(item.isVisible) button=\(item.button != nil) window=\(String(describing: item.button?.window?.frame), privacy: .public)")
        Task { [weak item] in
            try? await Task.sleep(for: .seconds(2))
            guard let item else { return }
            mnotchLog.notice("status item after 2s visible=\(item.isVisible) window=\(String(describing: item.button?.window?.frame), privacy: .public) onScreen=\(item.button?.window?.isVisible ?? false)")
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Alcove-style framed glyph: a continuous rounded shell, a compact notch
    /// attached to its top edge, and the Maclife double-peak M below. Drawing
    /// it as a template keeps it crisp on Retina and lets macOS tint it for
    /// light/dark menu bars and pressed state.
    private static func templateLogo() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            let display = NSBezierPath(
                roundedRect: NSRect(x: 1.7, y: 1.6, width: 14.6, height: 14.8),
                xRadius: 3.4,
                yRadius: 3.4
            )
            display.lineWidth = 1.05
            display.stroke()

            NSColor.black.setFill()
            let notch = NSBezierPath()
            notch.move(to: NSPoint(x: 5.9, y: 16.4))
            notch.line(to: NSPoint(x: 12.1, y: 16.4))
            notch.line(to: NSPoint(x: 11.9, y: 14.5))
            notch.curve(
                to: NSPoint(x: 10.5, y: 13.1),
                controlPoint1: NSPoint(x: 11.8, y: 13.7),
                controlPoint2: NSPoint(x: 11.2, y: 13.1)
            )
            notch.line(to: NSPoint(x: 7.5, y: 13.1))
            notch.curve(
                to: NSPoint(x: 6.1, y: 14.5),
                controlPoint1: NSPoint(x: 6.8, y: 13.1),
                controlPoint2: NSPoint(x: 6.2, y: 13.7)
            )
            notch.close()
            notch.fill()

            // Solid miniature of the overlapping Maclife mountain ribbons.
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 5.5, y: 9.3))
            mark.line(to: NSPoint(x: 3.0, y: 3.0))
            mark.line(to: NSPoint(x: 5.2, y: 3.0))
            mark.line(to: NSPoint(x: 8.3, y: 7.5))
            mark.close()
            mark.move(to: NSPoint(x: 11.4, y: 11.8))
            mark.line(to: NSPoint(x: 8.3, y: 7.5))
            mark.line(to: NSPoint(x: 15.0, y: 3.0))
            mark.close()
            mark.move(to: NSPoint(x: 8.3, y: 7.5))
            mark.line(to: NSPoint(x: 5.2, y: 3.0))
            mark.line(to: NSPoint(x: 15.0, y: 3.0))
            mark.close()
            mark.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

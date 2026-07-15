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
                roundedRect: NSRect(x: 1.8, y: 1.8, width: 14.4, height: 14.4),
                xRadius: 3.3,
                yRadius: 3.3
            )
            display.lineWidth = 1.0
            display.stroke()

            NSColor.black.setFill()

            // Slim notch centered on the top edge (narrower + shorter than the
            // display's rounded corners for a refined look).
            let notch = NSBezierPath()
            notch.move(to: NSPoint(x: 7.05, y: 16.2))
            notch.line(to: NSPoint(x: 10.95, y: 16.2))
            notch.line(to: NSPoint(x: 10.8, y: 15.2))
            notch.curve(
                to: NSPoint(x: 10.15, y: 14.8),
                controlPoint1: NSPoint(x: 10.72, y: 14.95),
                controlPoint2: NSPoint(x: 10.48, y: 14.8)
            )
            notch.line(to: NSPoint(x: 7.85, y: 14.8))
            notch.curve(
                to: NSPoint(x: 7.2, y: 15.2),
                controlPoint1: NSPoint(x: 7.52, y: 14.8),
                controlPoint2: NSPoint(x: 7.28, y: 14.95)
            )
            notch.close()
            notch.fill()

            // Maclife mountain range (favicon-ml.svg), scaled to fill the frame
            // down to the bottom edge so there's no hollow gap beneath it.
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                // SVG viewBox x∈[1.29,62.16], y∈[2.94,50.15] (top-down) → icon.
                NSPoint(
                    x: 3.4 + (x - 1.29) / 60.87 * 11.2,
                    y: 3.1 + (50.15 - y) / 47.21 * 10.1
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
            return true
        }
        image.isTemplate = true
        return image
    }
}

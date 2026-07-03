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

    /// The favicon-ml logo polygons drawn as a single black silhouette;
    /// isTemplate makes the system tint it for menu bar appearance/state.
    private static func templateLogo() -> NSImage {
        let logoW: CGFloat = 64
        let logoH: CGFloat = 54.75
        let width: CGFloat = 17
        let height = width * logoH / logoW
        let scale = width / logoW
        let polys: [[CGPoint]] = [
            [
                CGPoint(x: 13.77, y: 17.46), CGPoint(x: 1.29, y: 50.15),
                CGPoint(x: 12.29, y: 50.15), CGPoint(x: 27.56, y: 26.78),
            ],
            [
                CGPoint(x: 43.12, y: 2.94), CGPoint(x: 27.56, y: 26.78),
                CGPoint(x: 62.16, y: 50.15),
            ],
            [
                CGPoint(x: 27.56, y: 26.78), CGPoint(x: 12.29, y: 50.15),
                CGPoint(x: 62.16, y: 50.15),
            ],
        ]

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSColor.black.setFill()
            for points in polys {
                let path = NSBezierPath()
                for (i, p) in points.enumerated() {
                    let point = NSPoint(x: p.x * scale, y: (logoH - p.y) * scale)
                    if i == 0 { path.move(to: point) } else { path.line(to: point) }
                }
                path.close()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

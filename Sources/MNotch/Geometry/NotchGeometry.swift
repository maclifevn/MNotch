import AppKit

/// Physical (or simulated) notch metrics for one screen.
struct NotchGeometry: Equatable {
    /// Width of the hardware cutout (between the two auxiliary menu bar areas).
    let notchWidth: CGFloat
    /// Height of the hardware cutout (== menu bar height on notched Macs).
    let notchHeight: CGFloat
    /// True when the screen has a real notch; false for fake-notch external displays.
    let isPhysical: Bool

    static let fallbackWidth: CGFloat = 185
    static let fallbackHeight: CGFloat = 32

    @MainActor
    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        // User tuning offsets (Settings → General → Tuning).
        let dw = CGFloat(SettingsStore.shared.notchWidthOffset)
        let dh = CGFloat(SettingsStore.shared.notchHeightOffset)

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return NotchGeometry(
                notchWidth: max(80, screen.frame.width - left.width - right.width + dw),
                notchHeight: max(20, screen.safeAreaInsets.top + dh),
                isPhysical: true
            )
        }
        // Fake notch: match the external display's menu bar height so the
        // black shape reads as part of the bar.
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(
            notchWidth: max(80, fallbackWidth + dw),
            notchHeight: max(20, (menuBarHeight > 4 ? menuBarHeight : fallbackHeight) + dh),
            isPhysical: false
        )
    }
}

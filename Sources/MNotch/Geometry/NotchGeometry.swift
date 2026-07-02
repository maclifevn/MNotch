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

    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return NotchGeometry(
                notchWidth: screen.frame.width - left.width - right.width,
                notchHeight: screen.safeAreaInsets.top,
                isPhysical: true
            )
        }
        return NotchGeometry(
            notchWidth: fallbackWidth,
            notchHeight: fallbackHeight,
            isPhysical: false
        )
    }
}

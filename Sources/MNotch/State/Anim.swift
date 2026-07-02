import SwiftUI

/// The app's entire animation vocabulary, defined once. Every state change
/// animates with one of these — never inline ad-hoc curves.
enum Anim {
    /// Opening: slight overshoot, feels alive.
    static let open = Animation.spring(response: 0.38, dampingFraction: 0.72)
    /// Closing: crisp, no bounce.
    static let close = Animation.spring(response: 0.32, dampingFraction: 0.95)
    /// HUD sliver in/out and value changes.
    static let hud = Animation.snappy(duration: 0.25)
    /// Pops (battery, device connect).
    static let pop = Animation.spring(response: 0.42, dampingFraction: 0.75)

    /// Content swap inside the notch.
    @MainActor
    static var contentSwap: some Transition {
        BlurReplaceTransition(configuration: .downUp)
            .combined(with: ScaleTransition(0.9))
            .combined(with: OpacityTransition())
    }
}

import AppKit
import SwiftUI

/// The app's entire animation vocabulary, defined once. Every state change
/// animates with one of these — never inline ad-hoc curves. All members
/// respect the system Reduce Motion setting by degrading to quick fades.
@MainActor
enum Anim {
    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Opening: slight overshoot, feels alive.
    static var open: Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.38, dampingFraction: 0.72)
    }

    /// Closing: crisp, no bounce.
    static var close: Animation {
        reduceMotion
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.32, dampingFraction: 0.95)
    }

    /// HUD sliver in/out and value changes.
    static var hud: Animation {
        .snappy(duration: 0.25)
    }

    /// User-selectable HUD speed (Settings → Display/Sound).
    static func hud(_ speed: AnimSpeed) -> Animation {
        switch speed {
        case .smooth: .spring(response: 0.45, dampingFraction: 0.85)
        case .fast: .snappy(duration: 0.25)
        case .instant: .linear(duration: 0.01)
        }
    }

    /// Pops (battery, device connect).
    static var pop: Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.42, dampingFraction: 0.75)
    }

    /// Content swap inside the notch.
    static var contentSwap: some Transition {
        BlurReplaceTransition(configuration: .downUp)
            .combined(with: ScaleTransition(0.9))
            .combined(with: OpacityTransition())
    }
}

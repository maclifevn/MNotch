import AppKit
import SwiftUI

private struct NotchContentSwapModifier: ViewModifier {
    let active: Bool
    let richMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .scaleEffect(active && richMotion ? 0.94 : 1)
            .offset(y: active && richMotion ? -5 : 0)
            .blur(radius: active && richMotion ? 7 : 0)
    }
}

/// The app's entire animation vocabulary, defined once. Every state change
/// animates with one of these — never inline ad-hoc curves. All members
/// respect the system Reduce Motion setting by degrading to quick fades.
@MainActor
enum Anim {
    static var reduceMotion: Bool {
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
        reduceMotion ? .easeOut(duration: 0.14) : .snappy(duration: 0.25)
    }

    /// User-selectable HUD speed (Settings → Display/Sound).
    static func hud(_ speed: AnimSpeed) -> Animation {
        if reduceMotion, speed != .instant {
            return .easeOut(duration: 0.16)
        }
        return switch speed {
        case .smooth: Animation.spring(response: 0.45, dampingFraction: 0.85)
        case .fast: Animation.snappy(duration: 0.25)
        case .instant: Animation.linear(duration: 0.01)
        }
    }

    /// Pops (battery, device connect).
    static var pop: Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.42, dampingFraction: 0.75)
    }

    static var symbolReplace: ContentTransition {
        reduceMotion ? .opacity : .symbolEffect(.replace)
    }

    /// Content swap inside the notch.
    static var contentSwap: AnyTransition {
        let richMotion = !reduceMotion
        return .modifier(
            active: NotchContentSwapModifier(active: true, richMotion: richMotion),
            identity: NotchContentSwapModifier(active: false, richMotion: richMotion)
        )
    }
}

extension View {
    /// Decorative bounce is removed when macOS Reduce Motion is enabled.
    @MainActor
    @ViewBuilder
    func notchBounce() -> some View {
        if Anim.reduceMotion {
            self
        } else {
            symbolEffect(.bounce, options: .nonRepeating)
        }
    }
}

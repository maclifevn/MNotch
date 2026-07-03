import SwiftUI

/// Waveform bars styled per Settings → Now Playing.
struct StyledVisualizer: View {
    let isPlaying: Bool
    let accent: Color

    var body: some View {
        switch SettingsStore.shared.mediaWaveformStyle {
        case .monochrome:
            VisualizerView(isPlaying: isPlaying, color: .white.opacity(0.9))
        case .colored:
            VisualizerView(isPlaying: isPlaying, color: accent)
        case .gradient:
            VisualizerView(
                isPlaying: isPlaying,
                color: accent,
                gradient: [accent, accent.opacity(0.65), .white.opacity(0.85), accent]
            )
        }
    }
}

/// 3D flip used for artwork changes (Alcove's default), disabled via settings.
private struct FlipModifier: ViewModifier {
    var angle: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.4
            )
            .opacity(abs(angle) > 89 ? 0 : 1)
    }
}

extension AnyTransition {
    static var artworkFlip: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: FlipModifier(angle: 90),
                identity: FlipModifier(angle: 0)
            ),
            removal: .modifier(
                active: FlipModifier(angle: -90),
                identity: FlipModifier(angle: 0)
            )
        )
    }
}

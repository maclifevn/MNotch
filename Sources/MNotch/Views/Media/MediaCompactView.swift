import SwiftUI

/// Closed-state media chrome: album thumb hugging the left inner edge of the
/// notch, visualizer bars on the right, hardware cutout untouched in between.
struct MediaCompactView: View {
    let viewModel: NotchViewModel
    let media: MediaRemoteService
    var namespace: Namespace.ID

    var body: some View {
        HStack {
            ArtworkView(
                image: media.artwork,
                cornerRadius: 5,
                identity: media.playback.title + media.playback.artist
            )
            .frame(width: 20, height: 20)
                .matchedGeometryEffect(id: "artwork", in: namespace)

            Spacer(minLength: viewModel.geometry.notchWidth)

            if SettingsStore.shared.focusReplaceWaveform,
               AppServices.shared.focus.isFocused,
               let mode = AppServices.shared.focus.current {
                Image(systemName: mode.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 18, height: 14)
            } else if SettingsStore.shared.mediaDisableCompactWaveform {
                Color.clear.frame(width: 18, height: 14)
            } else {
                StyledVisualizer(
                    isPlaying: media.playback.isPlaying,
                    accent: media.accentColor
                )
                .frame(width: 18, height: 14)
            }
        }
        .padding(.horizontal, viewModel.topRadius + 5)
        .frame(height: viewModel.geometry.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.expand(.media)
        }
    }
}

/// Album artwork with a music-note placeholder while empty. `identity`
/// (track title/artist) keys the flip / blur-replace transition between
/// tracks; `badgeBundleID` overlays the source app icon when enabled.
struct ArtworkView: View {
    let image: NSImage?
    var cornerRadius: CGFloat
    var identity: String = ""
    var badgeBundleID: String = ""

    private var transition: AnyTransition {
        SettingsStore.shared.mediaDisableArtworkFlip
            ? AnyTransition(.blurReplace)
            : .artworkFlip
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.white.opacity(0.12))
            if let image {
                // Color.clear adopts the proposed frame, so the filling image
                // is clipped at the real bounds instead of overflowing them.
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .transition(transition)
                    .id(identity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(alignment: .bottomTrailing) {
            if SettingsStore.shared.mediaBadge == .appIcon,
               !badgeBundleID.isEmpty,
               let icon = ApplicationIconCache.shared.icon(for: badgeBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: cornerRadius > 10 ? 22 : 10, height: cornerRadius > 10 ? 22 : 10)
                    .offset(x: 3, y: 3)
                    .shadow(radius: 2)
            }
        }
        .animation(Anim.open, value: identity)
    }
}

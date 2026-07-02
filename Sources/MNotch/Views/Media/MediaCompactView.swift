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

            VisualizerView(
                isPlaying: media.playback.isPlaying,
                color: media.accentColor
            )
            .frame(width: 18, height: 14)
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
/// (track title/artist) keys the blur-replace transition between tracks.
struct ArtworkView: View {
    let image: NSImage?
    var cornerRadius: CGFloat
    var identity: String = ""

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.white.opacity(0.12))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.blurReplace)
                    .id(identity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .animation(.easeInOut(duration: 0.45), value: identity)
    }
}

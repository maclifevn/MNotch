import SwiftUI

/// Full player: artwork with colored glow, track info, seek, transport
/// controls, and volume — laid out under the hardware cutout.
struct MediaExpandedView: View {
    let viewModel: NotchViewModel
    let media: MediaRemoteService
    let audio: AudioOutputService
    var namespace: Namespace.ID

    @State private var scrubValue: Double?

    private var trackIdentity: String {
        media.playback.title + media.playback.artist
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            artwork
            VStack(alignment: .leading, spacing: 7) {
                trackInfo
                seekBar
                controls
            }
        }
        .padding(.top, viewModel.geometry.notchHeight + 4)
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    private var artwork: some View {
        ArtworkView(image: media.artwork, cornerRadius: 18, identity: trackIdentity)
            .frame(width: 96, height: 96)
            .matchedGeometryEffect(id: "artwork", in: namespace)
            .background {
                // Static-per-track glow: pre-rasterized, only its opacity and
                // color ever change — never blurred per frame during springs.
                if let image = media.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .drawingGroup()
                        .scaleEffect(1.12)
                        .blur(radius: 26)
                        .saturation(1.6)
                        .opacity(0.55)
                }
            }
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(media.playback.title.isEmpty ? "Not Playing" : media.playback.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(media.playback.artist)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: trackIdentity)
    }

    private var seekBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let duration = max(media.playback.duration, 1)
            let elapsed = scrubValue.map { $0 * duration }
                ?? media.playback.elapsed(at: timeline.date)
            VStack(spacing: 3) {
                CapsuleSlider(
                    value: elapsed / duration,
                    fill: media.accentColor,
                    onScrub: { scrubValue = $0 },
                    onCommit: { fraction in
                        media.seek(to: fraction * duration)
                        scrubValue = nil
                    }
                )
                .frame(height: 8)
                HStack {
                    Text(Self.timeString(elapsed))
                    Spacer()
                    Text("-" + Self.timeString(max(duration - elapsed, 0)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            TransportButton(symbol: "backward.fill", size: 13) {
                media.send(.previousTrack)
            }
            TransportButton(
                symbol: media.playback.isPlaying ? "pause.fill" : "play.fill",
                size: 19
            ) {
                media.send(.togglePlayPause)
            }
            .contentTransition(.symbolEffect(.replace))
            TransportButton(symbol: "forward.fill", size: 13) {
                media.send(.nextTrack)
            }

            Spacer(minLength: 12)

            Image(systemName: audio.muted || audio.volume == 0
                ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16)
            CapsuleSlider(
                value: audio.volume,
                onScrub: { audio.setVolume($0) },
                onCommit: { audio.setVolume($0) }
            )
            .frame(width: 86, height: 7)
        }
    }

    static func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size + 17, height: size + 17)
                .background(
                    Circle().fill(.white.opacity(hovering ? 0.14 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Anim.hud, value: hovering)
    }
}

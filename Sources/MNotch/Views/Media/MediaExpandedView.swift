import SwiftUI

/// Full player, laid out to match Alcove:
///   row 1 — artwork | title + artist | visualizer glyph
///   row 2 — elapsed · progress bar · remaining
///   row 3 — shuffle · prev · play/pause · next · output device
/// Video sources get a wide 16:9 artwork and no shuffle button.
struct MediaExpandedView: View {
    let viewModel: NotchViewModel
    let media: MediaRemoteService
    let audio: AudioOutputService
    var namespace: Namespace.ID

    @State private var scrubValue: Double?

    private var trackIdentity: String {
        media.playback.title + media.playback.artist
    }

    private var displayTitle: String {
        if media.playback.title.isEmpty { return "Not Playing" }
        return SettingsStore.shared.mediaHideTitleExtras
            ? media.playback.cleanTitle
            : media.playback.title
    }

    private var isWide: Bool {
        if media.playback.isVideo { return true }
        if let artwork = media.artwork, artwork.size.height > 0 {
            return artwork.size.width / artwork.size.height > 1.35
        }
        return false
    }

    var body: some View {
        VStack(spacing: 10) {
            topRow
            seekRow
            controlsRow
        }
        .padding(.top, viewModel.geometry.notchHeight - 12)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    // MARK: - Row 1

    private var topRow: some View {
        HStack(alignment: .center, spacing: 14) {
            artwork
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(media.playback.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Anim.hud, value: trackIdentity)

            StyledVisualizer(
                isPlaying: media.playback.isPlaying,
                accent: media.accentColor
            )
            .frame(width: 22, height: 16)
        }
        // Row 1 sits beside/below the camera cutout; the text block starts
        // after the artwork, clear of the cutout's left edge.
        .padding(.top, 10)
    }

    private var artwork: some View {
        ArtworkView(
            image: media.artwork,
            cornerRadius: isWide ? 10 : 14,
            identity: trackIdentity,
            badgeBundleID: media.playback.bundleIdentifier
        )
        .frame(width: isWide ? 86 : 62, height: isWide ? 48 : 62)
        .matchedGeometryEffect(id: "artwork", in: namespace)
        .background {
            // Static-per-track glow: pre-rasterized, only opacity/color change.
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 62, height: 62)
                    .drawingGroup()
                    .scaleEffect(1.15)
                    .blur(radius: 24)
                    .saturation(1.6)
                    .opacity(0.5)
            }
        }
        .animation(Anim.open, value: isWide)
    }

    // MARK: - Row 2

    private var seekRow: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            // Live streams / some browser videos report no duration; show a
            // full static bar and ignore seeks rather than divide by ~0.
            let seekable = media.playback.duration > 1
            let duration = max(media.playback.duration, 1)
            let elapsed = scrubValue.map { $0 * duration }
                ?? media.playback.elapsed(at: timeline.date)
            HStack(spacing: 10) {
                Text(seekable ? Self.timeString(elapsed) : "LIVE")
                CapsuleSlider(
                    value: seekable ? elapsed / duration : 1,
                    fill: .white,
                    onScrub: { if seekable { scrubValue = $0 } },
                    onCommit: { fraction in
                        if seekable {
                            media.seek(to: fraction * duration)
                        }
                        scrubValue = nil
                    }
                )
                .frame(height: 9)
                Text(seekable ? "-" + Self.timeString(max(duration - elapsed, 0)) : "")
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - Row 3

    private var controlsRow: some View {
        HStack {
            quickActionButton

            Spacer()
            TransportButton(symbol: "backward.fill", size: 17) {
                media.send(.previousTrack)
            }
            TransportButton(
                symbol: media.playback.isPlaying ? "pause.fill" : "play.fill",
                size: 25
            ) {
                media.send(.togglePlayPause)
            }
            .contentTransition(Anim.symbolReplace)
            TransportButton(symbol: "forward.fill", size: 17) {
                media.send(.nextTrack)
            }
            Spacer()

            Image(systemName: audio.outputSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 30, height: 30)
                .help(audio.outputName)
        }
    }

    /// Left control slot, chosen in Settings → Now Playing → Quick action.
    @ViewBuilder
    private var quickActionButton: some View {
        switch SettingsStore.shared.mediaQuickAction {
        case .shuffle:
            if media.playback.shuffleMode != nil {
                SideButton(
                    symbol: "shuffle",
                    active: media.playback.isShuffled,
                    tint: media.accentColor
                ) {
                    media.toggleShuffle()
                }
            } else {
                Color.clear.frame(width: 30, height: 30)
            }
        case .repeatMode:
            if let mode = media.playback.repeatMode {
                SideButton(
                    symbol: mode == 2 ? "repeat.1" : "repeat",
                    active: mode != 1,
                    tint: media.accentColor
                ) {
                    media.cycleRepeat()
                }
            } else {
                Color.clear.frame(width: 30, height: 30)
            }
        case .copy:
            SideButton(symbol: "link", active: false, tint: media.accentColor) {
                media.copyTrackInfo()
            }
        case .favorite:
            if media.playback.bundleIdentifier == "com.apple.Music" {
                SideButton(symbol: "star.fill", active: false, tint: media.accentColor) {
                    media.favoriteCurrentTrack()
                }
            } else {
                Color.clear.frame(width: 30, height: 30)
            }
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
                .frame(width: size + 21, height: size + 17)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.white.opacity(hovering ? 0.12 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Anim.hud, value: hovering)
    }
}

/// Small side control (shuffle) with an accent tint when active.
struct SideButton: View {
    let symbol: String
    let active: Bool
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? tint : .white.opacity(0.45))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(.white.opacity(hovering ? 0.12 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Anim.hud, value: hovering)
    }
}

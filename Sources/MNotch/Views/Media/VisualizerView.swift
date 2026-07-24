import SwiftUI

/// Decorative audio bars, Alcove-style: phase-shifted sines per bar, springing
/// to zero amplitude when paused. Runs at 24fps (organic enough for 4 bars)
/// and fully pauses its timeline shortly after playback stops, so an idle
/// notch costs nothing.
struct VisualizerView: View {
    var isPlaying: Bool
    var color: Color
    /// Per-bar colors (cycled); overrides `color` when set (gradient style).
    var gradient: [Color]? = nil
    var barCount = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var playStateChangedAt = Date.distantPast
    @State private var engineRunning = false
    @State private var stopTask: Task<Void, Never>?

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1 / 14,
            paused: !engineRunning || reduceMotion
        )) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // Ramp amplitude in/out over ~0.4s around play/pause.
                let sinceChange = timeline.date.timeIntervalSince(playStateChangedAt)
                let ramp = min(max(sinceChange / 0.4, 0), 1)
                let amplitude = isPlaying ? ramp : 1 - ramp

                let barWidth = size.width / (CGFloat(barCount) * 2 - 1)
                for i in 0..<barCount {
                    let phase = Double(i) * 0.9
                    let wobble = reduceMotion ? 0.55 : 0.55
                        + 0.45 * sin(t * (5.2 + Double(i) * 0.7) + phase)
                        * sin(t * 1.3 + phase * 2)
                    let height = max(
                        size.height * 0.14,
                        size.height * wobble * amplitude
                    )
                    let x = CGFloat(i) * barWidth * 2
                    let rect = CGRect(
                        x: x,
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    let barColor = gradient.map { $0[i % $0.count] } ?? color
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(barColor)
                    )
                }
            }
        }
        .onAppear {
            // No ramp on first render: a fresh view while paused must show
            // flat bars, not a frozen full-amplitude frame (distantPast makes
            // the ramp already complete in whichever direction applies).
            playStateChangedAt = .distantPast
            engineRunning = isPlaying && !reduceMotion
        }
        .onChange(of: isPlaying) {
            playStateChangedAt = Date()
            stopTask?.cancel()
            if isPlaying, !reduceMotion {
                engineRunning = true
            } else {
                // Keep rendering through the ramp-out, then halt the timeline.
                stopTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    engineRunning = false
                }
            }
        }
        .onChange(of: reduceMotion) {
            stopTask?.cancel()
            engineRunning = isPlaying && !reduceMotion
        }
    }
}

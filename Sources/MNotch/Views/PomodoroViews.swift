import SwiftUI

// MARK: - Closed-notch live activity

/// Closed-state Pomodoro chrome: phase glyph hugging the left inner edge,
/// mm:ss countdown on the right — mirroring MediaCompactView's layout.
struct PomodoroCompactView: View {
    let viewModel: NotchViewModel
    let pomodoro: PomodoroService

    private var tint: Color {
        pomodoro.phase == .work ? Color(red: 1.0, green: 0.42, blue: 0.36) : .green
    }

    var body: some View {
        HStack {
            Image(systemName: pomodoro.phase.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(pomodoro.isRunning ? tint : .white.opacity(0.45))
                .frame(width: 20, height: 20)

            Spacer(minLength: viewModel.geometry.notchWidth)

            Text(pomodoro.remainingText)
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(pomodoro.isRunning ? .white.opacity(0.92) : .white.opacity(0.5))
                .lineLimit(1)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, viewModel.topRadius + 5)
        .frame(height: viewModel.geometry.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.expand(.pomodoro)
        }
    }
}

// MARK: - Expanded tab

/// Pomodoro tab: progress ring with the countdown inside, phase + cycle dots,
/// and start/pause · skip · reset controls.
struct PomodoroTabView: View {
    let viewModel: NotchViewModel
    let pomodoro: PomodoroService

    private var tint: Color {
        pomodoro.phase == .work ? Color(red: 1.0, green: 0.42, blue: 0.36) : .green
    }

    var body: some View {
        HStack(spacing: 24) {
            ring
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pomodoro.phase.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    cycleDots
                }
                controls
            }
            Spacer(minLength: 0)
        }
        .padding(.top, viewModel.geometry.notchHeight + 6)
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: pomodoro.progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: pomodoro.progress)
            VStack(spacing: 0) {
                Text(pomodoro.remainingText)
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                Image(systemName: pomodoro.phase.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 108, height: 108)
    }

    /// One dot per work session toward the long break.
    private var cycleDots: some View {
        HStack(spacing: 4) {
            let total = max(Int(SettingsStore.shared.pomodoroCyclesPerLongBreak), 1)
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(
                        index < pomodoro.completedWorkSessions
                            ? tint : .white.opacity(0.18)
                    )
                    .frame(width: 5, height: 5)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                pomodoro.isRunning ? pomodoro.pause() : pomodoro.start()
            } label: {
                Label(
                    pomodoro.isRunning ? "Pause" : "Start",
                    systemImage: pomodoro.isRunning ? "pause.fill" : "play.fill"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(tint.opacity(0.85), in: Capsule())
            }
            .buttonStyle(.plain)

            if pomodoro.isActive {
                Button {
                    pomodoro.skip()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Skip to the next phase")
                .accessibilityLabel(L10n.string("Skip to the next phase"))

                Button {
                    pomodoro.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Reset the session")
                .accessibilityLabel(L10n.string("Reset the session"))
            }
        }
    }
}

// MARK: - Phase-change pop

/// Transient pop when a phase ends: phase glyph + name left, duration right.
struct PomodoroPopView: View {
    let title: String
    let symbol: String
    let detail: String
    let geometry: NotchGeometry

    var body: some View {
        PopWings(geometry: geometry) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(title == "Focus" ? Color(red: 1.0, green: 0.42, blue: 0.36) : .green)
                    .notchBounce()
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
        } right: {
            Text(detail)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

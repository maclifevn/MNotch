import Foundation
import Observation

/// Pomodoro timer: work → short break, with a long break after every N work
/// sessions. Completely inert (no timer, no observation) until the user starts
/// a session, so it can never affect the rest of the app at rest.
///
/// Remaining time derives from a wall-clock `endDate` rather than a decremented
/// counter, so display sleep or timer coalescing never drifts the countdown.
@MainActor
@Observable
final class PomodoroService {
    enum Phase: String {
        case work
        case shortBreak
        case longBreak

        var title: String {
            switch self {
            case .work: "Focus"
            case .shortBreak: "Break"
            case .longBreak: "Long Break"
            }
        }

        var symbol: String {
            switch self {
            case .work: "timer"
            case .shortBreak: "cup.and.saucer.fill"
            case .longBreak: "figure.walk"
            }
        }
    }

    private(set) var phase: Phase = .work
    private(set) var isRunning = false
    /// Work sessions completed in the current long-break cycle.
    private(set) var completedWorkSessions = 0
    /// End of the running phase; nil while paused/idle.
    private(set) var endDate: Date?
    /// Seconds left when paused (also seeds the initial display).
    private(set) var frozenRemaining: TimeInterval = 0
    /// Ticks once per second while running so SwiftUI re-reads `remaining`.
    private(set) var tick = 0

    /// Running or paused mid-session — drives the notch live activity.
    var isActive: Bool { isRunning || frozenRemaining > 0 }

    /// (ended, next) — fired when a phase completes naturally.
    @ObservationIgnored var onPhaseEnded: ((Phase, Phase) -> Void)?

    @ObservationIgnored private var timer: Timer?

    // MARK: - Derived state

    var remaining: TimeInterval {
        _ = tick
        if let endDate { return max(endDate.timeIntervalSinceNow, 0) }
        return frozenRemaining
    }

    var remainingText: String {
        let seconds = Int(remaining.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// 0…1 progress through the current phase (for the ring).
    var progress: Double {
        let total = duration(of: phase)
        guard total > 0 else { return 0 }
        return min(max(1 - remaining / total, 0), 1)
    }

    private func duration(of phase: Phase) -> TimeInterval {
        let settings = SettingsStore.shared
        switch phase {
        case .work: return settings.pomodoroWorkMinutes * 60
        case .shortBreak: return settings.pomodoroShortBreakMinutes * 60
        case .longBreak: return settings.pomodoroLongBreakMinutes * 60
        }
    }

    // MARK: - Controls

    func start() {
        if frozenRemaining > 0 {           // resume a paused session
            endDate = Date().addingTimeInterval(frozenRemaining)
            frozenRemaining = 0
        } else {
            endDate = Date().addingTimeInterval(duration(of: phase))
        }
        isRunning = true
        startTimer()
    }

    func pause() {
        guard isRunning else { return }
        frozenRemaining = remaining
        endDate = nil
        isRunning = false
        stopTimer()
    }

    /// Jump to the next phase immediately (counts a skipped work session).
    func skip() { advance(fireCallback: false) }

    func reset() {
        stopTimer()
        isRunning = false
        endDate = nil
        frozenRemaining = 0
        phase = .work
        completedWorkSessions = 0
    }

    // MARK: - Phase machine

    /// Pure transition rule, exposed for unit tests.
    nonisolated static func nextPhase(
        after phase: Phase,
        completedWorkSessions: Int,
        cyclesPerLongBreak: Int
    ) -> Phase {
        switch phase {
        case .work:
            return completedWorkSessions >= cyclesPerLongBreak ? .longBreak : .shortBreak
        case .shortBreak, .longBreak:
            return .work
        }
    }

    private func advance(fireCallback: Bool) {
        let ended = phase
        if ended == .work { completedWorkSessions += 1 }
        let next = Self.nextPhase(
            after: ended,
            completedWorkSessions: completedWorkSessions,
            cyclesPerLongBreak: Int(SettingsStore.shared.pomodoroCyclesPerLongBreak)
        )
        if next == .work, ended == .longBreak { completedWorkSessions = 0 }
        phase = next
        if fireCallback { onPhaseEnded?(ended, next) }

        if SettingsStore.shared.pomodoroAutoContinue || !fireCallback {
            endDate = Date().addingTimeInterval(duration(of: next))
            isRunning = true
            startTimer()
        } else {
            // Wait for the user: park the full next duration, paused.
            stopTimer()
            isRunning = false
            endDate = nil
            frozenRemaining = duration(of: next)
        }
    }

    // MARK: - Timer

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleTick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func handleTick() {
        guard isRunning else { return }
        tick &+= 1
        if remaining <= 0 { advance(fireCallback: true) }
    }
}

import AppKit
import Foundation

/// Pure state machine: one outstanding probe, one detection per episode.
/// Missing watchdog ticks mean the monitor/host was delayed too, which is not
/// evidence of a main-thread hang. Sleep and wake invalidate old probes.
struct MainThreadWatchdog {
    enum Signal: Equatable {
        case probe(UInt64), unresponsive(TimeInterval), recovered(TimeInterval)
        case delayedResponse(TimeInterval), watchdogDelayed(TimeInterval)
    }

    let threshold: TimeInterval
    let maximumTickGap: TimeInterval
    private(set) var lastResponse: TimeInterval
    private var lastTick: TimeInterval
    private var pendingSince: TimeInterval?
    private var sequence: UInt64 = 0
    private var detected = false
    private var suspended = false

    init(now: TimeInterval, threshold: TimeInterval = 5, maximumTickGap: TimeInterval = 3) {
        self.threshold = threshold
        self.maximumTickGap = maximumTickGap
        lastResponse = now
        lastTick = now
    }

    mutating func tick(at now: TimeInterval) -> [Signal] {
        guard !suspended else { lastTick = now; return [] }
        let gap = now - lastTick
        lastTick = now
        if gap > maximumTickGap {
            invalidate()
            return [.watchdogDelayed(gap), makeProbe(at: now)]
        }
        guard let pendingSince else { return [makeProbe(at: now)] }
        let elapsed = now - pendingSince
        guard elapsed >= threshold, !detected else { return [] }
        detected = true
        return [.unresponsive(elapsed)]
    }

    mutating func acknowledge(_ token: UInt64, at now: TimeInterval) -> [Signal]? {
        guard !suspended, token == sequence, let pendingSince else { return nil }
        if now - lastTick > maximumTickGap {
            let gap = now - lastTick
            lastTick = now
            invalidate()
            lastResponse = now
            return [.watchdogDelayed(gap)]
        }
        let elapsed = now - pendingSince
        let wasDetected = detected
        self.pendingSince = nil
        detected = false
        lastResponse = now
        if wasDetected { return [.recovered(elapsed)] }
        return elapsed >= threshold ? [.delayedResponse(elapsed)] : []
    }

    mutating func setSuspended(_ suspended: Bool, at now: TimeInterval) {
        self.suspended = suspended
        lastTick = now
        invalidate()
    }

    private mutating func invalidate() {
        sequence &+= 1
        pendingSince = nil
        detected = false
    }

    private mutating func makeProbe(at now: TimeInterval) -> Signal {
        sequence &+= 1
        pendingSince = now
        return .probe(sequence)
    }
}

final class AppHangMonitor: @unchecked Sendable {
    typealias Probe = @Sendable (@escaping @Sendable ([String: Bool]) -> Void) -> Void
    struct Configuration: Sendable {
        var tickInterval: TimeInterval = 1
        var threshold: TimeInterval = 5
        var maximumTickGap: TimeInterval = 3
        var checkpointInterval: TimeInterval = 5
    }
    private let queue = DispatchQueue(label: "com.mnotch.diagnostics.watchdog", qos: .utility)
    private let sampleQueue = DispatchQueue(label: "com.mnotch.diagnostics.sample", qos: .utility)
    private let recorder: DiagnosticRecorder
    private let probe: Probe
    private let sampler: @Sendable (UUID) -> DiagnosticStackSample
    private let configuration: Configuration
    private static let mainProbeMailbox = LatestValueMailbox<@Sendable ([String: Bool]) -> Void>()
    private var timer: DispatchSourceTimer? // all following state belongs to queue
    private var state = MainThreadWatchdog(now: ProcessInfo.processInfo.systemUptime)
    private var running = false
    private var runtime: [String: Bool] = [:]
    private var lastMainResponseAt: Date?
    private var lastCheckpoint: TimeInterval = 0
    private var lastSample: TimeInterval?
    private var sampleAttempts = 0
    private var observers: [NSObjectProtocol] = [] // main actor only

    init(recorder: DiagnosticRecorder,
         configuration: Configuration = .init(),
         probe: @escaping Probe = AppHangMonitor.mainRunLoopProbe,
         sampler: @escaping @Sendable (UUID) -> DiagnosticStackSample = DiagnosticStackSample.capture) {
        self.recorder = recorder
        self.configuration = configuration
        self.probe = probe
        self.sampler = sampler
    }

    @MainActor
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for (name, suspended) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.setSuspended(suspended)
            })
        }
        queue.async { [self] in
            guard !running else { return }
            running = true
            state = .init(now: ProcessInfo.processInfo.systemUptime, threshold: configuration.threshold,
                          maximumTickGap: configuration.maximumTickGap)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: configuration.tickInterval,
                           leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    @MainActor
    func stop() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        queue.async { [self] in
            running = false
            timer?.cancel()
            timer = nil
        }
    }

    private func setSuspended(_ suspended: Bool) {
        queue.async { [self] in
            guard running else { return }
            state.setSuspended(suspended, at: ProcessInfo.processInfo.systemUptime)
            recorder.record(.init(time: .now, kind: suspended ? .monitoringSuspended : .monitoringResumed,
                                  health: health()))
        }
    }

    private func tick() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        process(state.tick(at: now), now: now)
        if now - lastCheckpoint >= configuration.checkpointInterval {
            lastCheckpoint = now
            recorder.record(.init(time: .now, kind: .heartbeat, health: health()))
        }
    }

    private func health() -> DiagnosticHealthSnapshot {
        .capture(lastMainResponseAt: lastMainResponseAt,
                 mainResponseAge: ProcessInfo.processInfo.systemUptime - state.lastResponse, runtime: runtime)
    }

    private func process(_ signals: [MainThreadWatchdog.Signal], now: TimeInterval) {
        for signal in signals {
            switch signal {
            case .probe(let token):
                probe { [weak self] runtime in
                    guard let self else { return }
                    self.queue.async { [self] in
                        guard running else { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        guard let signals = state.acknowledge(token, at: now) else { return }
                        self.runtime = runtime
                        lastMainResponseAt = .now
                        process(signals, now: now)
                    }
                }
            case .unresponsive(let elapsed):
                let id = UUID()
                recorder.record(.init(time: .now, kind: .mainThreadUnresponsive, health: health(), elapsed: elapsed, relatedID: id))
                // Capture on a third queue: neither a stuck UI nor slow file
                // writes may stop the watchdog. At most two bounded attempts.
                if sampleAttempts < 2, lastSample.map({ now - $0 >= 60 }) ?? true {
                    sampleAttempts += 1
                    lastSample = now
                    sampleQueue.async { [recorder, sampler] in recorder.saveSample(sampler(id)) }
                }
            case .recovered(let elapsed):
                recorder.record(.init(time: .now, kind: .mainThreadRecovered, health: health(), elapsed: elapsed))
            case .delayedResponse(let elapsed):
                recorder.record(.init(time: .now, kind: .mainThreadDelayed, health: health(), elapsed: elapsed))
            case .watchdogDelayed(let elapsed):
                recorder.record(.init(time: .now, kind: .watchdogDelayed, health: health(), elapsed: elapsed))
            }
        }
    }

    static func mainRunLoopProbe(_ reply: @escaping @Sendable ([String: Bool]) -> Void) {
        // Common modes include menu tracking and modal panels. Dispatching only
        // to DispatchQueue.main can falsely flag an open menu as a hang.
        // A scheduler gap or sleep can invalidate a probe whose block is still
        // queued. Replace its reply rather than accumulating main-loop blocks.
        guard mainProbeMailbox.submit(reply) else { return }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            guard let latest = mainProbeMailbox.take() else { return }
            MainActor.assumeIsolated { latest(AppDiagnostics.runtimeState()) }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

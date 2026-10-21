import AppKit

/// One hardware operation in flight and one latest write target, even during
/// key repeat or rapid stop/start. A stale hardware lease returns keys to macOS
/// without blocking the event tap or queuing work behind a stalled XPC call.
@MainActor
@Observable
final class BrightnessService {
    @ObservationIgnored private let worker: BrightnessHardwareWorker
    @ObservationIgnored private let permitted: Bool
    @ObservationIgnored private let clock: @Sendable () -> TimeInterval
    @ObservationIgnored private let freshness: TimeInterval
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var pendingValue: Double?
    @ObservationIgnored private var displayID: CGDirectDisplayID = 0
    @ObservationIgnored private var sampledAt: TimeInterval?
    @ObservationIgnored private var lastPolled: Double?
    @ObservationIgnored private var writeFailed = false
    @ObservationIgnored private var lastFailure: BrightnessHardwareFailure?

    private(set) var brightness: Double = 0.5
    private(set) var isRunning = false
    private(set) var isResponsive = false
    @ObservationIgnored var onChanged: ((Double) -> Void)?

    init(
        hardware: any BrightnessHardwareAccess = DisplayServicesBrightnessHardware(),
        permitted: Bool = PrivateAPICompatibility.permits(.displayBrightness),
        freshness: TimeInterval = 2.5,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        worker = BrightnessHardwareWorker(hardware: hardware)
        self.permitted = permitted
        self.freshness = freshness
        self.clock = clock
    }

    var available: Bool {
        guard isRunning, isResponsive, !writeFailed, let sampledAt else { return false }
        return clock() - sampledAt <= freshness
    }

    var isUpdating: Bool { operationTask != nil }

    func start() {
        guard permitted else {
            AppDiagnostics.record(.brightness, .unsupportedOS)
            return
        }
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        writeFailed = false
        sampledAt = nil
        isResponsive = false
        lastPolled = nil
        requestRefresh(notifyChanges: false)
    }

    func startObserving() {
        guard isRunning, pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        isRunning = false
        isResponsive = false
        generation &+= 1
        pendingValue = nil
        lastPolled = nil
        sampledAt = nil
        // Retain the single flight until its actual completion. Cancelling a
        // Swift task cannot interrupt synchronous XPC, and clearing it here
        // would let each restart enqueue another blocked hardware operation.
    }

    func refresh() { requestRefresh(notifyChanges: true) }

    /// Optimistic HUD feedback is immediate; pending key steps coalesce to
    /// one final target while the dedicated worker finishes its current call.
    func step(up: Bool, fine: Bool) -> Double {
        guard available else { return brightness }
        let delta = (fine ? 1.0 / 64 : 1.0 / 16) * (up ? 1 : -1)
        brightness = min(max(brightness + delta, 0), 1)
        pendingValue = brightness
        drainWrite()
        return brightness
    }

    private func requestRefresh(notifyChanges: Bool) {
        if let sampledAt, clock() - sampledAt > freshness {
            isResponsive = false
            pendingValue = nil
        }
        guard isRunning, operationTask == nil else { return }
        if pendingValue != nil { drainWrite(); return }
        perform(.read, notifyChanges: notifyChanges)
    }

    private func drainWrite() {
        guard isRunning, operationTask == nil, let value = pendingValue else { return }
        pendingValue = nil
        perform(.write(value, displayID), notifyChanges: false)
    }

    private func perform(_ operation: BrightnessHardwareWorker.Operation, notifyChanges: Bool) {
        let generation = generation
        let startedAt = clock()
        operationTask = Task { [weak self, worker] in
            let result = await worker.perform(operation)
            guard let self else { return }
            self.operationTask = nil
            guard self.isRunning, self.generation == generation else {
                if self.isRunning { self.requestRefresh(notifyChanges: false) }
                return
            }
            // Once the lease expired, native keys may already have changed
            // brightness. Do not replay old pending steps over those changes.
            if self.clock() - startedAt > self.freshness { self.pendingValue = nil }
            switch result {
            case .success(let snapshot):
                guard snapshot.value.isFinite, (0...1).contains(snapshot.value), snapshot.displayID != 0 else {
                    self.fail(.readFailed(-1), operation: operation)
                    return
                }
                if self.displayID != snapshot.displayID {
                    self.pendingValue = nil
                    self.writeFailed = false
                }
                self.displayID = snapshot.displayID
                self.sampledAt = self.clock()
                self.isResponsive = true
                self.lastFailure = nil
                let previous = self.lastPolled
                self.lastPolled = snapshot.value
                // A completion must not roll the HUD backward over a newer
                // key step that is still waiting to be sent.
                if self.pendingValue == nil {
                    if self.brightness != snapshot.value { self.brightness = snapshot.value }
                    if notifyChanges, let previous, abs(previous - snapshot.value) > 0.004 {
                        self.onChanged?(snapshot.value)
                    }
                }
                self.drainWrite()
            case .failure(let failure): self.fail(failure, operation: operation)
            }
        }
    }

    private func fail(_ failure: BrightnessHardwareFailure, operation: BrightnessHardwareWorker.Operation) {
        isResponsive = false
        sampledAt = nil
        pendingValue = nil
        if case .write = operation { writeFailed = true }
        guard failure != lastFailure else { return }
        lastFailure = failure
        switch failure {
        case .writeFailed(let status): AppDiagnostics.record(.brightness, .writeFailed, status: status)
        case .readFailed(let status): AppDiagnostics.record(.brightness, .readFailed, status: status)
        case .unavailable, .displayChanged: AppDiagnostics.record(.brightness, .connectionFailed)
        }
    }
}

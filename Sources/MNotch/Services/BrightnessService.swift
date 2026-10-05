import AppKit

/// Display brightness via the private DisplayServices framework (works for the
/// built-in panel on Apple Silicon). If the symbols are missing, `available`
/// is false and brightness keys are passed through to the system untouched.
@MainActor
@Observable
final class BrightnessService {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// Function pointers remain valid because the framework stays loaded for
    /// process lifetime. The wrapper documents that immutable transfer to a
    /// detached task for Swift 6's strict concurrency checker.
    private struct ReadAccess: @unchecked Sendable { let function: GetFn }
    private struct StepAccess: @unchecked Sendable {
        let get: GetFn
        let set: SetFn
    }
    /// DisplayServices is synchronous and not documented for concurrent
    /// get/set calls. Serialize polling and rapid key repeats on one background
    /// actor so commands cannot complete out of order and make brightness jump.
    private actor HardwareGate {
        func read(using access: ReadAccess) -> Double? {
            BrightnessService.read(using: access.function)
        }

        func step(
            using access: StepAccess,
            fallback: Double,
            delta: Double
        ) -> Double {
            let current = BrightnessService.read(using: access.get) ?? fallback
            let target = min(max(current + delta, 0), 1)
            return access.set(CGMainDisplayID(), Float(target)) == 0
                ? target
                : current
        }
    }

    @ObservationIgnored private var getFn: GetFn?
    @ObservationIgnored private var setFn: SetFn?
    @ObservationIgnored private var frameworkHandle: UnsafeMutableRawPointer?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let hardware = HardwareGate()

    private(set) var brightness: Double = 0.5

    /// Observe-mode: fires when brightness changes externally (F1/F2 handled
    /// by the system while we don't have the event tap).
    @ObservationIgnored var onChanged: ((Double) -> Void)?
    @ObservationIgnored private var lastPolled: Double?
    @ObservationIgnored private var pollTimer: Timer?

    var available: Bool { getFn != nil && setFn != nil }

    /// Poll away from the main actor: DisplayServices performs a synchronous
    /// XPC round trip to CoreBrightness and can occasionally stall.
    func startObserving() {
        guard pollTimer == nil, available else { return }
        requestRefresh(notifyChanges: false)
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestRefresh(notifyChanges: true)
            }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func start() {
        guard PrivateAPICompatibility.permits(.displayBrightness) else {
            AppDiagnostics.record(.brightness, .unsupportedOS)
            return
        }
        guard frameworkHandle == nil else { return }
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        ) else {
            mnotchLog.notice("DisplayServices unavailable")
            return
        }
        frameworkHandle = handle
        if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
            getFn = unsafeBitCast(sym, to: GetFn.self)
        }
        if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
            setFn = unsafeBitCast(sym, to: SetFn.self)
        }
        requestRefresh(notifyChanges: false)
        mnotchLog.notice("brightness control available=\(self.available)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        lastPolled = nil
        // Keep this small system framework loaded for process lifetime. A
        // background XPC read may still be returning here; dlclose would race
        // its captured function pointer and can crash during feature toggles.
    }

    private nonisolated static func read(using getFn: GetFn) -> Double? {
        var value: Float = 0
        guard getFn(CGMainDisplayID(), &value) == 0, value.isFinite else { return nil }
        return SafeNumeric.unit(Double(value))
    }

    private func requestRefresh(notifyChanges: Bool) {
        guard refreshTask == nil, let getFn else { return }
        let access = ReadAccess(function: getFn)
        refreshTask = Task(priority: .utility) { [weak self, hardware] in
            let value = await hardware.read(using: access)
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            guard let value else { return }
            self.brightness = value
            if notifyChanges,
               let last = self.lastPolled,
               abs(last - value) > 0.004 {
                self.onChanged?(value)
            }
            self.lastPolled = value
        }
    }

    /// Keyboard-key step; returns the new value.
    func step(up: Bool, fine: Bool) async -> Double {
        guard let getFn, let setFn else { return brightness }
        let access = StepAccess(get: getFn, set: setFn)
        let fallback = brightness
        let delta = (fine ? 1.0 / 64 : 1.0 / 16) * (up ? 1.0 : -1.0)
        let result = await hardware.step(
            using: access,
            fallback: fallback,
            delta: delta
        )
        brightness = result
        lastPolled = result
        return result
    }
}

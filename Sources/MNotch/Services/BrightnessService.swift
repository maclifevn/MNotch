import AppKit

/// Display brightness via the private DisplayServices framework (works for the
/// built-in panel on Apple Silicon). If the symbols are missing, `available`
/// is false and brightness keys are passed through to the system untouched.
@MainActor
@Observable
final class BrightnessService {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    @ObservationIgnored private var getFn: GetFn?
    @ObservationIgnored private var setFn: SetFn?

    private(set) var brightness: Double = 0.5

    /// Observe-mode: fires when brightness changes externally (F1/F2 handled
    /// by the system while we don't have the event tap).
    @ObservationIgnored var onChanged: ((Double) -> Void)?
    @ObservationIgnored private var lastPolled: Double?
    @ObservationIgnored private var pollTimer: Timer?

    var available: Bool { getFn != nil && setFn != nil }

    /// Cheap 0.5s poll (one C call) so brightness-key presses show our HUD
    /// even without Accessibility.
    func startObserving() {
        guard pollTimer == nil, available else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.refresh() else { return }
                if let last = self.lastPolled, abs(last - self.brightness) > 0.004 {
                    self.onChanged?(self.brightness)
                }
                self.lastPolled = self.brightness
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func start() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        ) else {
            mnotchLog.notice("DisplayServices unavailable")
            return
        }
        if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
            getFn = unsafeBitCast(sym, to: GetFn.self)
        }
        if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
            setFn = unsafeBitCast(sym, to: SetFn.self)
        }
        refresh()
        mnotchLog.notice("brightness control available=\(self.available) value=\(self.brightness)")
    }

    @discardableResult
    func refresh() -> Bool {
        guard let getFn else { return false }
        var value: Float = 0
        guard getFn(CGMainDisplayID(), &value) == 0 else { return false }
        brightness = Double(value)
        return true
    }

    func setBrightness(_ newValue: Double) {
        guard let setFn else { return }
        let clamped = Float(min(max(newValue, 0), 1))
        if setFn(CGMainDisplayID(), clamped) == 0 {
            brightness = Double(clamped)
        }
    }

    /// Keyboard-key step; returns the new value.
    func step(up: Bool, fine: Bool) -> Double {
        refresh()
        let step = (fine ? 1.0 / 64 : 1.0 / 16) * (up ? 1 : -1)
        setBrightness(brightness + step)
        return brightness
    }
}

import AppKit

/// Selectors of the private CoreBrightness KeyboardBrightnessClient, exposed
/// through an @objc protocol so Swift can call them dynamically.
@objc private protocol KeyboardBrightnessClientLike {
    @objc optional func brightness(forKeyboard keyboardID: UInt64) -> Float
    @objc optional func setBrightness(_ brightness: Float, forKeyboard keyboardID: UInt64) -> Bool
    @objc optional func copyKeyboardBacklightIDs() -> [NSNumber]
}

/// Keyboard backlight via the private CoreBrightness framework. Verified at
/// runtime; when unavailable the illumination keys pass through untouched.
@MainActor
@Observable
final class KeyboardBacklightService {
    private struct HardwareAccess: @unchecked Sendable {
        let proxy: KeyboardBrightnessClientLike
        let keyboardID: UInt64
    }

    private actor HardwareGate {
        func read(_ access: HardwareAccess) -> Double? {
            guard let value = access.proxy.brightness?(forKeyboard: access.keyboardID)
            else { return nil }
            return Double(value)
        }

        func step(_ access: HardwareAccess, up: Bool) -> Double? {
            guard let current = access.proxy.brightness?(forKeyboard: access.keyboardID)
            else { return nil }
            let target = min(max(current + (up ? 1.0 / 16 : -1.0 / 16), 0), 1)
            guard access.proxy.setBrightness?(target, forKeyboard: access.keyboardID) == true
            else { return Double(current) }
            return Double(target)
        }
    }

    @ObservationIgnored private var client: AnyObject?
    @ObservationIgnored private var keyboardID: UInt64 = 1
    @ObservationIgnored private var frameworkHandle: UnsafeMutableRawPointer?
    @ObservationIgnored private let hardware = HardwareGate()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private(set) var level: Double = 0.5

    var available: Bool { client != nil }

    func start() {
        if frameworkHandle != nil {
            requestRefresh()
            return
        }
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_LAZY
        ) else {
            mnotchLog.notice("CoreBrightness KeyboardBrightnessClient unavailable")
            return
        }
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            dlclose(handle)
            mnotchLog.notice("CoreBrightness KeyboardBrightnessClient unavailable")
            return
        }
        frameworkHandle = handle
        let instance = cls.init()
        let proxy = unsafeBitCast(instance, to: KeyboardBrightnessClientLike.self)
        guard instance.responds(to: #selector(KeyboardBrightnessClientLike.brightness(forKeyboard:))),
              instance.responds(to: #selector(KeyboardBrightnessClientLike.setBrightness(_:forKeyboard:)))
        else {
            mnotchLog.notice("KeyboardBrightnessClient selectors missing")
            return
        }
        if instance.responds(to: #selector(KeyboardBrightnessClientLike.copyKeyboardBacklightIDs)),
           let ids = proxy.copyKeyboardBacklightIDs?(), let first = ids.first {
            keyboardID = first.uint64Value
        }
        client = instance
        requestRefresh()
        mnotchLog.notice("keyboard backlight available, id=\(self.keyboardID)")
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        // The private client can still be completing an XPC call on the gate.
        // Keep both it and CoreBrightness loaded for process lifetime; tearing
        // either down during a feature toggle risks executing unloaded code.
    }

    private var proxy: KeyboardBrightnessClientLike? {
        client.map { unsafeBitCast($0, to: KeyboardBrightnessClientLike.self) }
    }

    private func requestRefresh() {
        guard refreshTask == nil, let proxy else { return }
        let access = HardwareAccess(proxy: proxy, keyboardID: keyboardID)
        refreshTask = Task(priority: .utility) { [weak self, hardware] in
            let value = await hardware.read(access)
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            if let value { self.level = value }
        }
    }

    /// Keyboard-key step; returns the new value.
    func step(up: Bool) async -> Double {
        guard let proxy else { return level }
        let access = HardwareAccess(proxy: proxy, keyboardID: keyboardID)
        let result = await hardware.step(access, up: up)
        if let result { level = result }
        return level
    }
}

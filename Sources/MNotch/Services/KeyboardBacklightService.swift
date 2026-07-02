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
    @ObservationIgnored private var client: AnyObject?
    @ObservationIgnored private var keyboardID: UInt64 = 1

    private(set) var level: Double = 0.5

    var available: Bool { client != nil }

    func start() {
        guard dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_LAZY
        ) != nil,
            let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        else {
            mnotchLog.notice("CoreBrightness KeyboardBrightnessClient unavailable")
            return
        }
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
        refresh()
        mnotchLog.notice("keyboard backlight available, id=\(self.keyboardID) level=\(self.level)")
    }

    private var proxy: KeyboardBrightnessClientLike? {
        client.map { unsafeBitCast($0, to: KeyboardBrightnessClientLike.self) }
    }

    func refresh() {
        guard let value = proxy?.brightness?(forKeyboard: keyboardID) else { return }
        level = Double(value)
    }

    func setLevel(_ newValue: Double) {
        let clamped = Float(min(max(newValue, 0), 1))
        guard proxy?.setBrightness?(clamped, forKeyboard: keyboardID) == true else { return }
        level = Double(clamped)
    }

    /// Keyboard-key step; returns the new value.
    func step(up: Bool) -> Double {
        refresh()
        setLevel(level + (up ? 1.0 / 16 : -1.0 / 16))
        return level
    }
}

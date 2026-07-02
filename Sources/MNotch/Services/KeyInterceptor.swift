import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics

enum SystemKey: Int {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case illuminationUp = 21
    case illuminationDown = 22
}

/// Modifying CGEventTap on NX_SYSDEFINED events: swallows volume/brightness/
/// keyboard-backlight keys so Apple's OSD never fires, and lets us perform the
/// action + show our notch HUD instead. Requires Accessibility; without it the
/// app runs in observe-only mode (HUD shows next to Apple's).
@MainActor
@Observable
final class KeyInterceptor {
    private(set) var tapActive = false

    /// (key, keyDown, isRepeat, modifiers) -> consume?
    @ObservationIgnored
    var handler: ((SystemKey, Bool, Bool, NSEvent.ModifierFlags) -> Bool)?

    private var tap: CFMachPort?

    func start() {
        guard tap == nil else { return }

        // Prompt for Accessibility only once per install; after that, check
        // silently (the ad-hoc dev loop would otherwise prompt every launch).
        let promptedKey = "mnotch.ax.prompted"
        var trusted = AXIsProcessTrusted()
        if !trusted, !UserDefaults.standard.bool(forKey: promptedKey) {
            UserDefaults.standard.set(true, forKey: promptedKey)
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        }
        guard trusted else {
            mnotchLog.notice("accessibility not granted; HUD in observe-only mode")
            return
        }

        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            mnotchLog.error("failed to create event tap despite accessibility grant")
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapActive = true
        mnotchLog.notice("event tap active")
    }

    fileprivate func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8
        else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0xFFFF
        let keyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 1

        guard let key = SystemKey(rawValue: keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        let consumed = handler?(key, keyDown, isRepeat, nsEvent.modifierFlags) ?? false
        return consumed ? nil : Unmanaged.passUnretained(event)
    }
}

/// The tap's run loop source lives on the main run loop, so this runs on the
/// main thread — assumeIsolated is sound.
private func keyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated {
        interceptor.handle(event: event, type: type)
    }
}

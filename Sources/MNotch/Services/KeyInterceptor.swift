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

enum KeyTapInterruption: String, Sendable {
    case timeout
    case userInput
}

struct KeyTapSafetyLatch {
    private(set) var blocksRestart = false

    mutating func recordInterruption() {
        blocksRestart = true
    }

    mutating func recordNewPermissionGrant() {
        blocksRestart = false
    }
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
    @ObservationIgnored
    var onInterruption: ((KeyTapInterruption) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var interruptionScheduled = false
    private var safetyLatch = KeyTapSafetyLatch()

    func start() {
        guard tap == nil else { return }
        guard !safetyLatch.blocksRestart else {
            mnotchLog.error("event tap restart blocked by safety latch")
            return
        }

        // Permission prompts are user-initiated from the notch, menu bar,
        // Settings, or Welcome. Never throw an unexplained TCC dialog at launch.
        guard AXIsProcessTrusted() else {
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
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        tapActive = true
        mnotchLog.notice("event tap active")
    }

    func stop() {
        // Publish fail-open state before touching Core Graphics. A disabled tap
        // must never leave the rest of the app believing system keys are still
        // being consumed.
        tapActive = false
        let tap = self.tap
        let runLoopSource = self.runLoopSource
        self.tap = nil
        self.runLoopSource = nil
        interruptionScheduled = false

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }

    /// A disabled tap is latched off for the rest of the current permission
    /// grant. Only an observed false -> true TCC transition may clear it. This
    /// prevents app activation or a Settings refresh from racing a revocation
    /// and immediately installing another global tap.
    func allowRestartAfterPermissionGrant() {
        safetyLatch.recordNewPermissionGrant()
    }

    fileprivate func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            scheduleFailOpenTeardown(
                type == .tapDisabledByTimeout ? .timeout : .userInput
            )
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

    private func scheduleFailOpenTeardown(_ reason: KeyTapInterruption) {
        // Never call CGEvent.tapEnable or invalidate the Mach port from inside
        // its own callback. In particular, immediately re-enabling a tap that
        // WindowServer disabled for timeout defeats the system safety valve and
        // can create an endless disable/re-enable loop.
        safetyLatch.recordInterruption()
        guard !interruptionScheduled else { return }
        interruptionScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stop()
            self.onInterruption?(reason)
        }
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

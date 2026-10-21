import CoreGraphics
import Foundation

struct BrightnessSnapshot: Sendable {
    let value: Double
    let displayID: CGDirectDisplayID
}

enum BrightnessHardwareFailure: Error, Equatable, Sendable {
    case unavailable, readFailed(Int32), writeFailed(Int32), displayChanged
}

protocol BrightnessHardwareAccess: Sendable {
    func read() -> Result<BrightnessSnapshot, BrightnessHardwareFailure>
    func write(_ value: Double, displayID: CGDirectDisplayID) -> Result<BrightnessSnapshot, BrightnessHardwareFailure>
}

/// Accessed only by one serial worker. Framework loading and synchronous XPC
/// stay off both the main actor and Swift's cooperative executor. The loaded
/// framework remains resident because calls may outlive a service stop.
final class DisplayServicesBrightnessHardware: BrightnessHardwareAccess, @unchecked Sendable {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var handle: UnsafeMutableRawPointer?
    private var getFn: GetFn?
    private var setFn: SetFn?
    private var attemptedLoad = false

    func read() -> Result<BrightnessSnapshot, BrightnessHardwareFailure> {
        loadIfNeeded()
        guard getFn != nil, setFn != nil, let display = builtInDisplay() else { return .failure(.unavailable) }
        return read(displayID: display)
    }

    func write(_ value: Double, displayID: CGDirectDisplayID) -> Result<BrightnessSnapshot, BrightnessHardwareFailure> {
        guard value.isFinite, (0...1).contains(value), let setFn else { return .failure(.unavailable) }
        // Never redirect an old queued command to another display after a
        // clamshell/hot-plug change, or to an external primary display.
        guard builtInDisplay() == displayID else { return .failure(.displayChanged) }
        let status = setFn(displayID, Float(value))
        guard status == 0 else { return .failure(.writeFailed(status)) }
        return read(displayID: displayID)
    }

    private func read(displayID: CGDirectDisplayID) -> Result<BrightnessSnapshot, BrightnessHardwareFailure> {
        guard let getFn else { return .failure(.unavailable) }
        var value: Float = -1
        let status = getFn(displayID, &value)
        guard status == 0 else { return .failure(.readFailed(status)) }
        guard value.isFinite, (0...1).contains(value) else { return .failure(.readFailed(-1)) }
        return .success(.init(value: Double(value), displayID: displayID))
    }

    private func loadIfNeeded() {
        guard !attemptedLoad else { return }
        attemptedLoad = true
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY | RTLD_LOCAL
        ) else { return }
        self.handle = handle
        if let symbol = dlsym(handle, "DisplayServicesGetBrightness") { getFn = unsafeBitCast(symbol, to: GetFn.self) }
        if let symbol = dlsym(handle, "DisplayServicesSetBrightness") { setFn = unsafeBitCast(symbol, to: SetFn.self) }
    }

    private func builtInDisplay() -> CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

final class BrightnessHardwareWorker: @unchecked Sendable {
    enum Operation: Sendable { case read, write(Double, CGDirectDisplayID) }
    private let hardware: any BrightnessHardwareAccess
    private let queue = DispatchQueue(label: "com.mnotch.brightness-hardware", qos: .userInitiated)

    init(hardware: any BrightnessHardwareAccess) { self.hardware = hardware }

    func perform(_ operation: Operation) async -> Result<BrightnessSnapshot, BrightnessHardwareFailure> {
        await withCheckedContinuation { continuation in
            queue.async {
                switch operation {
                case .read: continuation.resume(returning: self.hardware.read())
                case .write(let value, let display):
                    continuation.resume(returning: self.hardware.write(value, displayID: display))
                }
            }
        }
    }
}

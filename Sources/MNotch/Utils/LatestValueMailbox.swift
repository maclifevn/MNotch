import Foundation

/// Coalesces a callback storm BEFORE it crosses onto the main actor.
final class LatestValueMailbox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Value?
    private var scheduled = false

    func submit(_ value: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        latest = value
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        defer { latest = nil; scheduled = false }
        return latest
    }
}

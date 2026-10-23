import Darwin
import Foundation

/// App termination cannot rely on an asyncAfter block surviving process exit.
/// Track only process groups created/verified by our launch boundaries.
final class SubprocessLifecycle: @unchecked Sendable {
    static let shared = SubprocessLifecycle()
    private let lock = NSLock()
    private var groups: Set<pid_t> = []
    private var stopping = false

    var isShuttingDown: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    var activeGroupCount: Int {
        lock.lock(); defer { lock.unlock() }
        return groups.count
    }

    func register(_ group: pid_t) {
        guard group > 0, group != getpgrp() else { return }
        lock.lock()
        let killImmediately = stopping
        if !killImmediately { groups.insert(group) }
        lock.unlock()
        // Also covers a launch finishing after shutdown began.
        if killImmediately { kill(-group, SIGKILL) }
    }

    func unregister(_ group: pid_t) {
        lock.lock(); defer { lock.unlock() }
        groups.remove(group)
    }

    func beginShutdown() {
        lock.lock()
        stopping = true
        let ownedGroups = groups
        groups.removeAll()
        lock.unlock()
        for group in ownedGroups { kill(-group, SIGKILL) }
    }
}

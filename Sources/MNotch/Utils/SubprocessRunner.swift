import Foundation
import Darwin

/// Cancellation is synchronized with launch; cancelling before PID assignment
/// cannot miss a newly spawned child. Every child owns a process group.
final class SubprocessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var pid: pid_t?
    fileprivate let lifecycle: SubprocessLifecycle

    init(lifecycle: SubprocessLifecycle = .shared) { self.lifecycle = lifecycle }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let pid { kill(-pid, lifecycle.isShuttingDown ? SIGKILL : SIGTERM) }
    }

    fileprivate func launched(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        self.pid = pid
        lifecycle.register(pid)
        if cancelled { kill(-pid, lifecycle.isShuttingDown ? SIGKILL : SIGTERM) }
    }

    fileprivate func finish() {
        lock.lock(); defer { lock.unlock() }
        if let pid { lifecycle.unregister(pid) }
        pid = nil
    }
}

enum SubprocessRunner {
    struct Request: Sendable {
        let executable: String
        var arguments: [String] = []
        var environment: [String: String] = ProcessInfo.processInfo.environment
        var workingDirectory: String?
        var timeout: TimeInterval = 8
        var outputLimit: Int = 2 * 1_024 * 1_024
        var component: DiagnosticComponent = .subprocess
    }

    enum Completion: Equatable, Sendable {
        case exited(Int32), timedOut, cancelled, outputLimit, launchFailed(Int32)
    }

    struct Result: Sendable {
        let stdout: Data
        let stderr: Data
        let completion: Completion
        let elapsed: TimeInterval
        var succeeded: Bool { completion == .exited(0) }
    }

    static func run(_ request: Request) async -> Result {
        let cancellation = SubprocessCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Blocking POSIX polling belongs on a GCD worker, never a
                // cooperative Swift executor or the main actor.
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: runSync(request, cancellation: cancellation))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func runSync(
        _ request: Request,
        cancellation: SubprocessCancellation = SubprocessCancellation()
    ) -> Result {
        let started = ProcessInfo.processInfo.systemUptime
        var out = Data(), err = Data()
        func result(_ completion: Completion) -> Result {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let code: DiagnosticCode
            let status: Int32?
            switch completion {
            case .exited(let exit): code = .exited; status = exit
            case .launchFailed(let error): code = .launchFailed; status = error
            case .timedOut: code = .timedOut; status = nil
            case .cancelled: code = .cancelled; status = nil
            case .outputLimit: code = .outputLimit; status = nil
            }
            AppDiagnostics.record(request.component, code, status: status, elapsed: elapsed)
            return Result(stdout: out, stderr: err, completion: completion, elapsed: elapsed)
        }
        guard !cancellation.isCancelled, !cancellation.lifecycle.isShuttingDown else { return result(.cancelled) }
        guard request.timeout.isFinite, request.timeout > 0, request.outputLimit > 0,
              !request.executable.utf8.contains(0),
              request.arguments.allSatisfy({ !$0.utf8.contains(0) }),
              request.environment.allSatisfy({ !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) })
        else { return result(.launchFailed(EINVAL)) }

        var stdoutFD: [Int32] = [-1, -1], stderrFD: [Int32] = [-1, -1]
        guard pipe(&stdoutFD) == 0 else { return result(.launchFailed(errno)) }
        defer { for fd in stdoutFD where fd >= 0 { close(fd) } }
        guard pipe(&stderrFD) == 0 else { return result(.launchFailed(errno)) }
        defer { for fd in stderrFD where fd >= 0 { close(fd) } }
        for fd in [stdoutFD[0], stderrFD[0]] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
            else { return result(.launchFailed(errno)) }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return result(.launchFailed(ENOMEM)) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return result(.launchFailed(ENOMEM)) }
        defer { posix_spawnattr_destroy(&attributes) }
        var setup = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        setup |= posix_spawn_file_actions_adddup2(&actions, stdoutFD[1], STDOUT_FILENO)
        setup |= posix_spawn_file_actions_adddup2(&actions, stderrFD[1], STDERR_FILENO)
        setup |= posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        setup |= posix_spawnattr_setpgroup(&attributes, 0)
        if let directory = request.workingDirectory {
            guard !directory.utf8.contains(0) else { return result(.launchFailed(EINVAL)) }
            setup |= posix_spawn_file_actions_addchdir_np(&actions, directory)
        }
        guard setup == 0 else { return result(.launchFailed(setup)) }

        let arguments = ([request.executable] + request.arguments).map { strdup($0) }
        let environment = request.environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            for value in arguments { free(value) }
            for value in environment { free(value) }
        }
        guard arguments.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil })
        else { return result(.launchFailed(ENOMEM)) }
        var pid: pid_t = 0
        let launch = (arguments + [nil]).withUnsafeBufferPointer { argv in
            (environment + [nil]).withUnsafeBufferPointer { envp in
                posix_spawn(&pid, request.executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard launch == 0 else { return result(.launchFailed(launch)) }
        cancellation.launched(pid)
        defer { cancellation.finish() }
        // Only the child owns these writing ends after spawn.
        close(stdoutFD[1]); stdoutFD[1] = -1
        close(stderrFD[1]); stderrFD[1] = -1

        let deadline = started + request.timeout
        var completion: Completion?
        var terminationAt: TimeInterval?
        var didKill = false
        var bytes = [UInt8](repeating: 0, count: 16_384)
        func drain(_ descriptor: Int32, into data: inout Data) {
            // A child producing continuously cannot monopolize this worker or
            // prevent cancellation/deadline checks.
            for _ in 0..<8 {
                let count = read(descriptor, &bytes, bytes.count)
                guard count > 0 else { break }
                let remaining = max(0, request.outputLimit - out.count - err.count - data.count)
                data.append(contentsOf: bytes.prefix(min(count, remaining)))
                if count > remaining { completion = .outputLimit; break }
            }
        }

        while true {
            // Pass locals to avoid overlapping access to captured out/err.
            var chunk = Data()
            drain(stdoutFD[0], into: &chunk); out.append(chunk)
            chunk = Data()
            drain(stderrFD[0], into: &chunk); err.append(chunk)
            let now = ProcessInfo.processInfo.systemUptime
            if completion == nil {
                if cancellation.isCancelled || cancellation.lifecycle.isShuttingDown { completion = .cancelled }
                else if now >= deadline { completion = .timedOut }
            }
            if completion != nil, terminationAt == nil {
                kill(-pid, SIGTERM)
                terminationAt = now
            }
            if let terminationAt, now - terminationAt >= 0.25, !didKill {
                kill(-pid, SIGKILL)
                didKill = true
            }
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                // Kill descendants that inherited pipes even when the leader
                // exited successfully. Never wait for their EOF indefinitely.
                kill(-pid, SIGKILL)
                chunk = Data(); drain(stdoutFD[0], into: &chunk); out.append(chunk)
                chunk = Data(); drain(stderrFD[0], into: &chunk); err.append(chunk)
                let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                return result(completion ?? .exited(code))
            }
            if waited < 0, errno != EINTR { return result(completion ?? .launchFailed(errno)) }
            if let terminationAt, now - terminationAt >= 1.25 {
                // SIGKILL is normally immediately reaped. An uninterruptible
                // kernel wait must not hold the caller indefinitely.
                let reapingPID = pid
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    while waitpid(reapingPID, &status, 0) < 0 && errno == EINTR {}
                }
                return result(completion ?? .timedOut)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

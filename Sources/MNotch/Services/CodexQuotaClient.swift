import AppKit
import Foundation

/// Small, read-only Codex App Server client. It reuses the user's existing
/// Codex login and only requests account rate-limit snapshots.
@MainActor
final class CodexQuotaClient {
    var onSnapshot: ((CodexQuotaSnapshot) -> Void)?
    var onUnavailable: ((String) -> Void)?

    private var process: Process?
    private var ownedProcessGroup: pid_t?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var initialized = false
    private var intentionallyStopped = false
    private var nextRequestID = 2
    private var lastSnapshot: CodexQuotaSnapshot?
    private var outputStream: BoundedPipeStream?
    private var readerTask: Task<Void, Never>?
    private var responseTimeoutTask: Task<Void, Never>?
    private var pendingRequestID: Int?
    private var retryAfter = Date.distantPast
    private let binaryOverride: URL?

    init(binary: URL? = nil) { binaryOverride = binary }

    func start() {
        intentionallyStopped = false
        launchIfNeeded()
    }

    func refresh() {
        if process?.isRunning == true, initialized {
            requestRateLimits()
        } else {
            launchIfNeeded()
        }
    }

    func stop() {
        intentionallyStopped = true
        tearDown()
    }

    private func launchIfNeeded() {
        guard process?.isRunning != true, Date() >= retryAfter,
              !SubprocessLifecycle.shared.isShuttingDown else { return }
        tearDown()
        guard let binary = binaryOverride ?? Self.findCodexBinary() else {
            onUnavailable?("Codex app or CLI not found")
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = binary
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let outputStream = BoundedPipeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            outputStream.read(handle)
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.didTerminate(process: process, status: status)
            }
        }

        do {
            try process.run()
            let pid = process.processIdentifier
            let ownedGroup = getpgid(pid) == pid ? pid : nil
            if let ownedGroup { SubprocessLifecycle.shared.register(ownedGroup) }
            // Non-blocking stdin: a codex process that stops draining its input
            // would otherwise fill the pipe buffer and park the main thread in
            // write(2) forever (see send()). Only our write end is affected —
            // the child inherited a separate description for the read end.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0,
                  fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) == 0
            else {
                outputStream.close(output.fileHandleForReading)
                Self.terminate(process, group: ownedGroup)
                onUnavailable?("Codex connection unavailable")
                return
            }
            self.process = process
            ownedProcessGroup = ownedGroup
            inputPipe = input
            outputPipe = output
            self.outputStream = outputStream
            readerTask = Task { [weak self] in
                for await data in outputStream.stream {
                    guard !Task.isCancelled, let self, self.process === process else { return }
                    if outputStream.overflowed {
                        self.failConnection()
                        return
                    }
                    self.receive(data)
                    await Task.yield()
                }
                guard !Task.isCancelled, let self, self.process === process else { return }
                self.failConnection()
            }
            outputBuffer.removeAll(keepingCapacity: true)
            initialized = false
            armResponseTimeout(id: 1, process: process, seconds: 10)
            send([
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "mnotch",
                        "title": "MNotch",
                        "version": Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? "dev",
                    ],
                ],
            ])
        } catch {
            outputStream.close(output.fileHandleForReading)
            process.terminationHandler = nil
            self.process = nil
            inputPipe = nil
            outputPipe = nil
            onUnavailable?("Couldn't start Codex")
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        guard data.count <= 1_024 * 1_024 - outputBuffer.count else {
            failConnection()
            return
        }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            handleLine(line)
            guard process != nil else { return }
        }
    }

    private func handleLine(_ data: Data) {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let responseID = (root["id"] as? NSNumber)?.intValue
        if responseID == pendingRequestID, responseID != nil {
            responseTimeoutTask?.cancel()
            responseTimeoutTask = nil
            pendingRequestID = nil
        }
        if responseID == 1, root["result"] != nil {
            initialized = true
            send(["method": "initialized", "params": [:]])
            requestRateLimits()
            return
        }

        if let snapshot = CodexQuotaParser.snapshot(from: data) {
            let merged = snapshot.merging(over: lastSnapshot)
            lastSnapshot = merged
            onSnapshot?(merged)
            return
        }

        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String,
           root["id"] != nil {
            onUnavailable?(message.contains("auth") ? "Sign in to Codex" : "Codex quota unavailable")
        }
    }

    private func requestRateLimits() {
        guard initialized, pendingRequestID == nil, let process else { return }
        let id = nextRequestID
        nextRequestID = nextRequestID == Int.max ? 2 : nextRequestID + 1
        armResponseTimeout(id: id, process: process, seconds: 10)
        send(["method": "account/rateLimits/read", "id": id])
    }

    /// Write one JSON-RPC line to the child's stdin. The write end is
    /// non-blocking and every request is far below PIPE_BUF, so the write is
    /// atomic: it either goes out whole or reports EAGAIN. A codex process that
    /// has stopped reading therefore costs a dropped request and a recycled
    /// child instead of a permanently frozen main thread.
    private func send(_ object: [String: Any]) {
        guard let handle = inputPipe?.fileHandleForWriting,
              var data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        data.append(0x0A)

        let descriptor = handle.fileDescriptor
        let written = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return write(descriptor, base, buffer.count)
        }
        guard written != data.count else { return }

        if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            mnotchLog.error("Codex app-server stopped reading stdin; recycling it")
            onUnavailable?("Codex quota unavailable")
        } else {
            onUnavailable?("Codex connection closed")
        }
        // Either way the request stream is broken; drop the child so the next
        // refresh starts a clean one.
        recycle()
    }

    /// Tear down a broken child without marking the client stopped, so the next
    /// refresh launches a replacement.
    private func recycle() {
        retryAfter = Date().addingTimeInterval(5)
        tearDown()
    }

    private func failConnection() {
        AppDiagnostics.record(.codex, .connectionFailed)
        onUnavailable?("Codex quota unavailable")
        recycle()
    }

    private func armResponseTimeout(id: Int, process: Process, seconds: Double) {
        pendingRequestID = id
        responseTimeoutTask?.cancel()
        responseTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.process === process,
                  self.pendingRequestID == id else { return }
            self.failConnection()
        }
    }

    private func tearDown() {
        readerTask?.cancel()
        readerTask = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        pendingRequestID = nil
        if let handle = outputPipe?.fileHandleForReading { outputStream?.close(handle) }
        outputStream = nil
        try? inputPipe?.fileHandleForWriting.close()
        if let process {
            process.terminationHandler = nil
            Self.terminate(process, group: ownedProcessGroup)
        }
        process = nil
        ownedProcessGroup = nil
        inputPipe = nil
        outputPipe = nil
        initialized = false
        outputBuffer.removeAll(keepingCapacity: false)
    }

    private nonisolated static func terminate(_ process: Process, group: pid_t?) {
        if SubprocessLifecycle.shared.isShuttingDown {
            if let group {
                kill(-group, SIGKILL)
                SubprocessLifecycle.shared.unregister(group)
            } else if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return
        }
        if let group {
            kill(-group, SIGTERM)
        } else if process.isRunning {
            process.terminate()
        } else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            // A leader can exit on TERM while a descendant ignores it and
            // keeps the pipe open. Escalate the group captured at launch even
            // after Foundation has reported the leader's termination.
            if let group {
                kill(-group, SIGKILL)
                SubprocessLifecycle.shared.unregister(group)
            }
            else if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func didTerminate(process terminatedProcess: Process, status: Int32) {
        guard process === terminatedProcess else { return }
        tearDown()
        guard !intentionallyStopped else { return }
        retryAfter = Date().addingTimeInterval(5)
        onUnavailable?(status == 0 ? "Codex quota disconnected" : "Codex quota unavailable")
    }

    static func findCodexBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationURLs: [URL]? = nil,
        isExecutableFile: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        var paths: [String] = [
            environment["MNOTCH_CODEX_BINARY"],
            environment["CODEX_BINARY"],
        ].compactMap { $0 }

        // Launch Services finds apps even when they have been moved or renamed.
        // The current Codex app can still be named ChatGPT.app on disk.
        let registeredApps = applicationURLs ?? ["com.openai.codex", "com.openai.chat"]
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let apps = registeredApps + [
            URL(fileURLWithPath: "/Applications/Codex.app"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            homeDirectory.appendingPathComponent("Applications/Codex.app"),
            homeDirectory.appendingPathComponent("Applications/ChatGPT.app"),
        ]
        for app in apps {
            paths += [
                // Newer releases embed the CLI as a separate application.
                "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "Contents/Resources/codex",
            ].map { app.appendingPathComponent($0).path }
        }

        paths += [
            homeDirectory.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]

        if let path = environment["PATH"] {
            paths += path.split(separator: ":").map { String($0) + "/codex" }
        }

        var seen = Set<String>()
        return paths.lazy
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0) }
            .first { isExecutableFile($0.path) }
    }
}

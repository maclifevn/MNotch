import Foundation

/// Small, read-only Codex App Server client. It reuses the user's existing
/// Codex login and only requests account rate-limit snapshots.
@MainActor
final class CodexQuotaClient {
    var onSnapshot: ((CodexQuotaSnapshot) -> Void)?
    var onUnavailable: ((String) -> Void)?

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var initialized = false
    private var intentionallyStopped = false
    private var nextRequestID = 2
    private var lastSnapshot: CodexQuotaSnapshot?

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
        initialized = false
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        inputPipe?.fileHandleForWriting.closeFile()
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        inputPipe = nil
        outputPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
    }

    private func launchIfNeeded() {
        guard process?.isRunning != true else { return }
        guard let binary = Self.findCodexBinary() else {
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

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.receive(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.didTerminate(process: process, status: status)
            }
        }

        do {
            try process.run()
            self.process = process
            inputPipe = input
            outputPipe = output
            outputBuffer.removeAll(keepingCapacity: true)
            initialized = false
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
            self.process = nil
            inputPipe = nil
            outputPipe = nil
            onUnavailable?("Couldn't start Codex")
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            handleLine(line)
        }
    }

    private func handleLine(_ data: Data) {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if (root["id"] as? NSNumber)?.intValue == 1, root["result"] != nil {
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
        guard initialized else { return }
        let id = nextRequestID
        nextRequestID += 1
        send(["method": "account/rateLimits/read", "id": id])
    }

    private func send(_ object: [String: Any]) {
        guard let handle = inputPipe?.fileHandleForWriting,
              var data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            onUnavailable?("Codex connection closed")
        }
    }

    private func didTerminate(process terminatedProcess: Process, status: Int32) {
        // A manual refresh may already have launched a replacement while the
        // old process's termination callback was crossing onto the main actor.
        guard process === terminatedProcess else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        initialized = false
        guard !intentionallyStopped else { return }
        onUnavailable?(status == 0 ? "Codex quota disconnected" : "Codex quota unavailable")
    }

    private static func findCodexBinary() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var paths: [String] = [
            environment["MNOTCH_CODEX_BINARY"],
            environment["CODEX_BINARY"],
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/Codex.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSHomeDirectory() + "/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ].compactMap { $0 }

        if let path = environment["PATH"] {
            paths += path.split(separator: ":").map { String($0) + "/codex" }
        }

        let fm = FileManager.default
        return paths.lazy
            .map { URL(fileURLWithPath: $0) }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }
}

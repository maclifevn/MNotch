import Darwin
import Foundation
import os

struct DiagnosticSessionMetadata: Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let processID: Int32
    let bootSessionID: String
    let appVersion: String
    let appBuild: String
    let macOSVersion: String
    let macOSBuild: String
    let model: String
    let physicalMemoryBytes: UInt64

    static func current() -> Self {
        func sysctlString(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return "unknown" }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "unknown" }
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return .init(id: UUID(), startedAt: .now, processID: getpid(),
                     bootSessionID: sysctlString("kern.bootsessionuuid"),
                     appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                     appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
                     macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                     macOSBuild: sysctlString("kern.osversion"), model: sysctlString("hw.model"),
                     physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }
}

struct DiagnosticHealthSnapshot: Codable, Sendable {
    let time: Date
    let uptime: TimeInterval
    let lastMainResponseAt: Date?
    let mainResponseAge: TimeInterval
    let runtime: [String: Bool]
    let residentMemoryBytes: UInt64?
    let cpuTimeSeconds: Double?

    static func capture(lastMainResponseAt: Date?, mainResponseAge: TimeInterval,
                        runtime: [String: Bool]) -> Self {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var usage = rusage()
        let hasUsage = getrusage(RUSAGE_SELF, &usage) == 0
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return .init(time: .now, uptime: ProcessInfo.processInfo.systemUptime,
                     lastMainResponseAt: lastMainResponseAt, mainResponseAge: max(0, mainResponseAge),
                     runtime: runtime, residentMemoryBytes: result == KERN_SUCCESS ? info.resident_size : nil,
                     cpuTimeSeconds: hasUsage ? cpu : nil)
    }
}

struct DiagnosticLogEntry: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case sessionStarted, sessionEnded, event, heartbeat, previousSessionUnclosed
        case mainThreadUnresponsive, mainThreadRecovered, mainThreadDelayed
        case monitoringSuspended, monitoringResumed, watchdogDelayed, stackSample
    }

    let time: Date
    let kind: Kind
    var event: DiagnosticEvent? = nil
    var health: DiagnosticHealthSnapshot? = nil
    var elapsed: TimeInterval? = nil
    var relatedID: UUID? = nil

    var isRoutine: Bool { kind == .heartbeat || (kind == .event && event?.isRoutineSuccess == true) }
}

struct DiagnosticStackSample: Codable, Sendable {
    enum Outcome: String, Codable, Sendable { case captured, unavailable, timedOut, outputLimit, cancelled }
    let id: UUID
    let time: Date
    let outcome: Outcome
    let exitStatus: Int32?
    let text: String?

    /// Keep stacks and image UUIDs, excluding the process/path header and all
    /// absolute paths. Never collect another process or include its output.
    static func sanitizedStack(_ data: Data) -> String? {
        let raw = String(decoding: data, as: UTF8.self)
        guard let start = raw.range(of: "Call graph:\n") else { return nil }
        return raw[start.lowerBound...].components(separatedBy: "\n").map { line in
            // Paths can contain spaces. Removing only a whitespace-delimited
            // token would leave private folder names behind.
            guard let slash = line.firstIndex(of: "/") else { return line }
            return String(line[..<slash]) + "<path>"
        }.joined(separator: "\n")
    }

    static func capture(id: UUID) -> Self {
        let result = SubprocessRunner.runSync(.init(
            executable: "/usr/bin/sample",
            arguments: [String(getpid()), "2", "10", "-file", "/dev/stdout"],
            timeout: 8, outputLimit: 512 * 1024, component: .watchdog
        ))
        let text = sanitizedStack(result.stdout)
        let outcome: Outcome
        let status: Int32?
        switch result.completion {
        case .exited(let code): outcome = code == 0 && text != nil ? .captured : .unavailable; status = code
        case .launchFailed(let code): outcome = .unavailable; status = code
        case .timedOut: outcome = .timedOut; status = nil
        case .outputLimit: outcome = .outputLimit; status = nil
        case .cancelled: outcome = .cancelled; status = nil
        }
        return .init(id: id, time: .now, outcome: outcome, exitStatus: status, text: text)
    }
}

struct DiagnosticSessionState: Codable, Sendable {
    let metadata: DiagnosticSessionMetadata
    var lastUpdated: Date
    var cleanExit = false
    var mainThreadUnresponsive = false
    var monitoringSuspended = false
    var lastHealth: DiagnosticHealthSnapshot? = nil
    var incidents: [DiagnosticLogEntry] = []
}

struct DiagnosticSessionArchive: Codable, Sendable {
    let state: DiagnosticSessionState
    let entries: [DiagnosticLogEntry]
    let samples: [DiagnosticStackSample]
}

struct DiagnosticHistory: Codable, Sendable {
    let storageAvailable: Bool
    let sessions: [DiagnosticSessionArchive]
}

/// Used only on DiagnosticRecorder's file queue. Each session owns its files;
/// opening a new session never overwrites the previous run's evidence.
final class DiagnosticFileStore {
    struct Limits: Sendable {
        var sessions = 5
        var journalBytes = 512 * 1024
        var sampleBytes = 512 * 1024
        var samplesPerSession = 2
    }

    private let directory: URL
    private let limits: Limits
    private var state: DiagnosticSessionState?
    private var sessionDirectory: URL?
    private var handle: FileHandle?
    private var journalBytes = 0
    private var sampleCount = 0
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL, limits: Limits = .init()) {
        self.directory = directory
        self.limits = limits
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    deinit { try? handle?.close() }

    func begin(_ metadata: DiagnosticSessionMetadata) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let previous = sessionStates()
        let destination = directory.appending(path: "session-\(metadata.id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        state = .init(metadata: metadata, lastUpdated: metadata.startedAt)
        sessionDirectory = destination
        try openJournal()
        var entries = [DiagnosticLogEntry(time: metadata.startedAt, kind: .sessionStarted)]
        for (_, old) in previous where !old.cleanExit && !isLive(old, bootSessionID: metadata.bootSessionID) {
            entries.append(.init(time: metadata.startedAt, kind: .previousSessionUnclosed, relatedID: old.metadata.id))
        }
        try append(entries)
        // Do not prune another running instance, or follow a symlink out of
        // this directory. Only recognized, inactive session directories count.
        let inactive = previous.filter { !isLive($0.1, bootSessionID: metadata.bootSessionID) }
        for (url, _) in inactive.dropFirst(max(0, limits.sessions - 1)) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func isLive(_ state: DiagnosticSessionState, bootSessionID: String) -> Bool {
        !state.cleanExit && state.metadata.bootSessionID == bootSessionID && bootSessionID != "unknown"
            && state.metadata.processID > 0 && kill(state.metadata.processID, 0) == 0
    }

    func append(_ entries: [DiagnosticLogEntry]) throws {
        guard let sessionDirectory, state != nil else { return }
        for entry in entries {
            var data = try encoder.encode(entry)
            data.append(0x0A)
            guard data.count <= limits.journalBytes else { continue }
            if journalBytes + data.count > limits.journalBytes {
                try handle?.synchronize()
                try handle?.close()
                handle = nil
                let previous = sessionDirectory.appending(path: "events.previous.jsonl")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: sessionDirectory.appending(path: "events.jsonl"), to: previous)
                try openJournal()
            }
            try handle?.write(contentsOf: data)
            journalBytes += data.count
            state?.lastUpdated = entry.time
            if let health = entry.health { state?.lastHealth = health }
            if !entry.isRoutine {
                // Keep a small incident trail even after routine media polls
                // rotate both journal segments. Health remains in lastHealth.
                var incident = entry
                incident.health = nil
                state?.incidents.append(incident)
                if let count = state?.incidents.count, count > 32 { state?.incidents.removeFirst(count - 32) }
            }
            switch entry.kind {
            case .mainThreadUnresponsive: state?.mainThreadUnresponsive = true
            case .mainThreadRecovered, .mainThreadDelayed: state?.mainThreadUnresponsive = false
            case .monitoringSuspended: state?.monitoringSuspended = true; state?.mainThreadUnresponsive = false
            case .monitoringResumed: state?.monitoringSuspended = false; state?.mainThreadUnresponsive = false
            case .watchdogDelayed: state?.mainThreadUnresponsive = false
            case .sessionEnded: state?.cleanExit = true
            default: break
            }
        }
        // Routine helper exits may stay buffered for at most one checkpoint
        // interval. Important events and every 5-second heartbeat sync now.
        if entries.contains(where: { !$0.isRoutine || $0.kind == .heartbeat }) { try checkpoint() }
    }

    func saveSample(_ sample: DiagnosticStackSample) throws {
        guard let sessionDirectory, sampleCount < limits.samplesPerSession else { return }
        var bounded = sample
        var data = try encoder.encode(bounded)
        if data.count > limits.sampleBytes {
            let prefix = sample.text.map { String(decoding: $0.utf8.prefix(limits.sampleBytes / 8), as: UTF8.self) }
            bounded = .init(id: sample.id, time: sample.time, outcome: .outputLimit,
                            exitStatus: sample.exitStatus, text: prefix)
            data = try encoder.encode(bounded)
        }
        guard data.count <= limits.sampleBytes else { return }
        try atomicWrite(data, to: sessionDirectory.appending(path: "sample-\(sample.id.uuidString).json"))
        sampleCount += 1
        try append([.init(time: sample.time, kind: .stackSample, relatedID: sample.id)])
    }

    func finish() throws {
        try append([.init(time: .now, kind: .sessionEnded)])
        try handle?.close()
        handle = nil
    }

    func history(storageAvailable: Bool) -> DiagnosticHistory {
        let sessions = sessionStates().prefix(limits.sessions).map { url, state in
            let entries = ["events.previous.jsonl", "events.jsonl"].flatMap { name -> [DiagnosticLogEntry] in
                guard let data = try? BoundedFileReader.read(url.appending(path: name), limit: limits.journalBytes) else { return [] }
                // A power loss can truncate the last line; earlier records
                // must remain readable instead of invalidating the whole log.
                return data.split(separator: 0x0A).compactMap { try? decoder.decode(DiagnosticLogEntry.self, from: Data($0)) }
            }
            let samples = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { recognizedID($0, prefix: "sample-", suffix: ".json") != nil }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .prefix(limits.samplesPerSession).compactMap { file -> DiagnosticStackSample? in
                    guard let data = try? BoundedFileReader.read(file, limit: limits.sampleBytes) else { return nil }
                    return try? decoder.decode(DiagnosticStackSample.self, from: data)
                }
            return DiagnosticSessionArchive(state: state, entries: entries, samples: samples)
        }
        return .init(storageAvailable: storageAvailable, sessions: sessions)
    }

    private func sessionStates() -> [(URL, DiagnosticSessionState)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return urls.compactMap { url -> (URL, DiagnosticSessionState)? in
            guard let id = recognizedID(url, prefix: "session-", suffix: ""),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let data = try? BoundedFileReader.read(url.appending(path: "session.json"), limit: 32 * 1024),
                  let state = try? decoder.decode(DiagnosticSessionState.self, from: data),
                  state.metadata.id == id else { return nil }
            return (url, state)
        }.sorted { $0.1.metadata.startedAt > $1.1.metadata.startedAt }
    }

    private func recognizedID(_ url: URL, prefix: String, suffix: String) -> UUID? {
        let name = url.lastPathComponent
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    private func openJournal() throws {
        guard let sessionDirectory else { return }
        let fd = open(sessionDirectory.appending(path: "events.jsonl").path,
                      O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(fd)
            throw POSIXError(.EINVAL)
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        journalBytes = Int(info.st_size)
    }

    private func checkpoint() throws {
        guard let state, let sessionDirectory else { return }
        try handle?.synchronize()
        try atomicWrite(try encoder.encode(state), to: sessionDirectory.appending(path: "session.json"))
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Bounded, nonblocking intake; no disk work runs on the caller or watchdog.
/// A stalled/full disk cannot create an unbounded queue of logging closures.
final class DiagnosticRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mnotch.diagnostics.files", qos: .utility)
    private let lock = NSLock()
    private let store: DiagnosticFileStore
    private var accepting = false
    private var started = false
    private var scheduled = false
    private var pending: [DiagnosticLogEntry] = []
    private var storageAvailable = false // file queue only
    private let capacity = 256

    init(directory: URL, limits: DiagnosticFileStore.Limits = .init()) {
        store = DiagnosticFileStore(directory: directory, limits: limits)
    }

    func start(metadata: DiagnosticSessionMetadata? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        accepting = true
        queue.async { [self] in
            do { try store.begin(metadata ?? .current()); storageAvailable = true }
            catch { reportStorageFailure() }
        }
    }

    func record(_ entry: DiagnosticLogEntry) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        if pending.count == capacity {
            if let index = pending.firstIndex(where: \.isRoutine) { pending.remove(at: index) }
            else if entry.isRoutine { return }
            else { pending.removeFirst() }
        }
        pending.append(entry)
        guard !scheduled else { return }
        scheduled = true
        queue.async { [self] in drain() }
    }

    func saveSample(_ sample: DiagnosticStackSample) {
        // The watchdog limits attempts to two per session, independently of
        // whether storage or the system sampler is currently available.
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        queue.async { [self] in
            guard storageAvailable else { return }
            do { try store.saveSample(sample) } catch { reportStorageFailure() }
        }
    }

    func history() async -> DiagnosticHistory {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                drain()
                continuation.resume(returning: store.history(storageAvailable: storageAvailable))
            }
        }
    }

    /// applicationWillTerminate cannot await. Only the final flush may wait,
    /// for at most 200 ms; an unavailable disk must never prevent quitting.
    @discardableResult
    func finish(timeout: TimeInterval = 0.2) -> Bool {
        lock.lock()
        accepting = false
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            drain()
            if storageAvailable {
                do { try store.finish() } catch { reportStorageFailure() }
            }
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    private func drain() {
        lock.lock()
        let entries = pending
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        lock.unlock()
        guard storageAvailable, !entries.isEmpty else { return }
        do { try store.append(entries) } catch { reportStorageFailure() }
    }

    private func reportStorageFailure() {
        storageAvailable = false
        Logger(subsystem: "com.mnotch.app", category: "diagnostics").error("persistent diagnostics storage unavailable")
    }
}

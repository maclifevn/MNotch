import Darwin
import Foundation
import XCTest
@testable import MNotch

final class PersistentDiagnosticsTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func metadata(_ second: TimeInterval = 0) -> DiagnosticSessionMetadata {
        .init(id: UUID(), startedAt: Date(timeIntervalSince1970: second), processID: -1,
              bootSessionID: "test-boot", appVersion: "test", appBuild: "1", macOSVersion: "27.2",
              macOSBuild: "test", model: "test-mac", physicalMemoryBytes: 32 * 1024 * 1024 * 1024)
    }

    func testUnclosedSessionAndHangEvidenceSurviveRelaunch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = metadata(1)
        let incidentID = UUID()
        do {
            let store = DiagnosticFileStore(directory: directory)
            try store.begin(old)
            let health = DiagnosticHealthSnapshot(time: Date(timeIntervalSince1970: 10), uptime: 20,
                lastMainResponseAt: Date(timeIntervalSince1970: 5), mainResponseAge: 5,
                runtime: ["eventTapActive": true], residentMemoryBytes: 50_000_000, cpuTimeSeconds: 1.5)
            try store.append([.init(time: health.time, kind: .mainThreadUnresponsive,
                                    health: health, elapsed: 5, relatedID: incidentID)])
            try store.saveSample(.init(id: incidentID, time: health.time, outcome: .captured,
                                       exitStatus: 0, text: "Call graph:\n main waiting"))
            // No finish: simulate Force Quit, a crash, or a forced reboot.
        }
        let reopened = DiagnosticFileStore(directory: directory)
        try reopened.begin(metadata(30))
        let history = reopened.history(storageAvailable: true)
        XCTAssertEqual(history.sessions.count, 2)
        XCTAssertTrue(history.sessions[0].entries.contains {
            $0.kind == .previousSessionUnclosed && $0.relatedID == old.id
        })
        let previous = history.sessions[1]
        XCTAssertFalse(previous.state.cleanExit)
        XCTAssertTrue(previous.state.mainThreadUnresponsive)
        XCTAssertEqual(previous.state.lastHealth?.runtime["eventTapActive"], true)
        XCTAssertEqual(previous.state.lastHealth?.residentMemoryBytes, 50_000_000)
        XCTAssertEqual(previous.samples.first?.id, incidentID)
        XCTAssertEqual(previous.samples.first?.text, "Call graph:\n main waiting")
        XCTAssertTrue(previous.entries.contains { $0.kind == .mainThreadUnresponsive })
    }

    func testCleanShutdownIsNotReportedAsUnclosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticFileStore(directory: directory)
        try store.begin(metadata(1))
        try store.finish()
        let reopened = DiagnosticFileStore(directory: directory)
        try reopened.begin(metadata(2))
        let history = reopened.history(storageAvailable: true)
        XCTAssertTrue(history.sessions[1].state.cleanExit)
        XCTAssertFalse(history.sessions[0].entries.contains { $0.kind == .previousSessionUnclosed })
    }

    func testRotationRetainsIncidentsAndRecoversCompleteLinesBeforeDamagedTail() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = metadata()
        let limits = DiagnosticFileStore.Limits(journalBytes: 1024)
        let store = DiagnosticFileStore(directory: directory, limits: limits)
        try store.begin(session)
        try store.append([.init(time: .now, kind: .mainThreadUnresponsive, elapsed: 5),
                          .init(time: .now, kind: .mainThreadRecovered, elapsed: 9)])
        for _ in 0..<100 {
            let event = DiagnosticEvent(time: .now, component: .media, code: .exited, status: 0, elapsed: 0.1)
            try store.append([.init(time: .now, kind: .event, event: event)])
        }
        try store.append([.init(time: .now, kind: .heartbeat)])
        let sessionDirectory = directory.appending(path: "session-\(session.id.uuidString)")
        for name in ["events.jsonl", "events.previous.jsonl"] {
            let size = try FileManager.default.attributesOfItem(atPath: sessionDirectory.appending(path: name).path)[.size] as! NSNumber
            XCTAssertLessThanOrEqual(size.intValue, limits.journalBytes)
        }
        let file = try FileHandle(forWritingTo: sessionDirectory.appending(path: "events.jsonl"))
        try file.seekToEnd()
        try file.write(contentsOf: Data("{\"incomplete\":".utf8))
        try file.close()
        let archive = try XCTUnwrap(store.history(storageAvailable: true).sessions.first)
        XCTAssertTrue(archive.entries.contains { $0.kind == .event && $0.event?.status == 0 })
        XCTAssertTrue(archive.state.incidents.contains { $0.kind == .mainThreadUnresponsive })
        XCTAssertTrue(archive.state.incidents.contains { $0.kind == .mainThreadRecovered })
        XCTAssertFalse(archive.state.mainThreadUnresponsive)
    }

    func testRetentionAndSampleLimitsDoNotRemoveUnrelatedFilesOrFollowSessionSymlinks() throws {
        let directory = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let sentinel = outside.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let link = directory.appending(path: "session-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let unrelated = directory.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        let limits = DiagnosticFileStore.Limits(sessions: 2, samplesPerSession: 1)
        for second in 0..<4 {
            let store = DiagnosticFileStore(directory: directory, limits: limits)
            try store.begin(metadata(Double(second)))
            for _ in 0..<3 {
                try store.saveSample(.init(id: UUID(), time: .now, outcome: .unavailable, exitStatus: 1, text: nil))
            }
            try store.finish()
        }
        let history = DiagnosticFileStore(directory: directory, limits: limits).history(storageAvailable: true)
        XCTAssertEqual(history.sessions.count, 2)
        XCTAssertEqual(history.sessions.map(\.samples.count), [1, 1])
        let sessions = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("session-") && $0.lastPathComponent != link.lastPathComponent }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    func testFilesArePrivateAndExportIncludesPreviousSessionsAndSanitizedStacks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = metadata()
        let store = DiagnosticFileStore(directory: directory)
        try store.begin(session)
        let raw = "Process: secret\nPath: /Users/alice/private/MNotch\nCall graph:\n main (/Users/alice/My Private/source.swift:2)\nBinary Images:\n MNotch <SAMPLE-UUID> /Volumes/Private/MNotch\n"
        let text = try XCTUnwrap(DiagnosticStackSample.sanitizedStack(Data(raw.utf8)))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("alice"))
        XCTAssertFalse(text.contains("Private"))
        XCTAssertFalse(text.contains("/Volumes"))
        XCTAssertTrue(text.contains("SAMPLE-UUID"))
        try store.saveSample(.init(id: UUID(), time: .now, outcome: .captured, exitStatus: 0, text: text))
        try store.finish()
        let sessionDirectory = directory.appending(path: "session-\(session.id.uuidString)")
        for file in try FileManager.default.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: nil) {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(mode.intValue & 0o777, 0o600)
        }
        var report = AppDiagnostics.Report(schemaVersion: 1, createdAt: .now, appVersion: "test",
            appBuild: "1", macOSVersion: "27.2", architecture: "arm64", runtime: [:], events: [])
        report.history = store.history(storageAvailable: true)
        let decoded = try JSONDecoder.iso8601.decode(AppDiagnostics.Report.self, from: AppDiagnostics.encode(report))
        XCTAssertEqual(decoded.history?.sessions.first?.samples.first?.text, text)
        XCTAssertNil(DiagnosticStackSample.sanitizedStack(Data("access denied".utf8)))
    }

    func testOversizedSampleStillRecordsTruncationWithinDiskLimit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticFileStore(directory: directory, limits: .init(sampleBytes: 1024))
        try store.begin(metadata())
        try store.saveSample(.init(id: UUID(), time: .now, outcome: .captured, exitStatus: 0,
                                   text: String(repeating: "\"stack\"\n", count: 10_000)))
        let sample = try XCTUnwrap(store.history(storageAvailable: true).sessions.first?.samples.first)
        XCTAssertEqual(sample.outcome, .outputLimit)
        XCTAssertNotNil(sample.text)
    }

    func testRecorderFlushesShutdownAndRejectsLaterEvents() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticRecorder(directory: directory)
        recorder.start(metadata: metadata())
        for _ in 0..<2000 { recorder.record(.init(time: .now, kind: .heartbeat)) }
        recorder.record(.init(time: .now, kind: .mainThreadUnresponsive, elapsed: 5))
        XCTAssertTrue(recorder.finish(timeout: 2))
        recorder.record(.init(time: .now, kind: .mainThreadRecovered, elapsed: 8))
        let history = await recorder.history()
        XCTAssertTrue(history.storageAvailable)
        let session = try XCTUnwrap(history.sessions.first)
        XCTAssertTrue(session.state.cleanExit)
        XCTAssertTrue(session.state.incidents.contains { $0.kind == .mainThreadUnresponsive })
        XCTAssertFalse(session.entries.contains { $0.kind == .mainThreadRecovered })
    }

    func testUnavailableStorageDoesNotPreventLoggingOrShutdown() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "not-a-directory")
        try Data().write(to: file)
        let recorder = DiagnosticRecorder(directory: file)
        recorder.start(metadata: metadata())
        recorder.record(.init(time: .now, kind: .mainThreadUnresponsive, elapsed: 5))
        let history = await recorder.history()
        XCTAssertFalse(history.storageAvailable)
        XCTAssertTrue(history.sessions.isEmpty)
        XCTAssertTrue(recorder.finish(timeout: 1))
    }

    func testActualSystemSamplerCapturesOnlyOurProcess() async throws {
        let sample = await Task.detached { DiagnosticStackSample.capture(id: UUID()) }.value
        XCTAssertEqual(sample.outcome, .captured, "sampler exit: \(String(describing: sample.exitStatus))")
        let text = try XCTUnwrap(sample.text)
        XCTAssertTrue(text.hasPrefix("Call graph:"))
        XCTAssertFalse(text.contains(NSHomeDirectory()))
        XCTAssertFalse(text.contains("Path:"))
        XCTAssertLessThan(text.utf8.count, 512 * 1024)
    }

    @MainActor
    func testActualBlockedMainRunLoopIsSampledAndHistorySurvivesRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticRecorder(directory: directory)
        let old = metadata()
        recorder.start(metadata: old)
        let monitor = AppHangMonitor(recorder: recorder,
            configuration: .init(tickInterval: 0.025, threshold: 0.15, maximumTickGap: 2, checkpointInterval: 0.05),
            probe: { reply in
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { reply([:]) }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            })
        monitor.start()
        defer { monitor.stop(); recorder.finish(timeout: 1) }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            Thread.sleep(forTimeInterval: 1)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        var sampled = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let history = await recorder.history()
            if history.sessions.first?.samples.first?.outcome == .captured {
                sampled = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(sampled)
        // Read through a new store before any clean shutdown marker is written.
        let restarted = DiagnosticFileStore(directory: directory)
        try restarted.begin(metadata(100))
        let previous = try XCTUnwrap(restarted.history(storageAvailable: true).sessions.last)
        XCTAssertEqual(previous.state.metadata.id, old.id)
        XCTAssertTrue(previous.entries.contains { $0.kind == .mainThreadUnresponsive })
        XCTAssertTrue(previous.entries.contains { $0.kind == .mainThreadRecovered })
        XCTAssertEqual(previous.samples.first?.outcome, .captured)
    }

    @MainActor
    func testMonitorRecordsHangSampleAndRecoveryWithoutMainActorAcknowledgment() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticRecorder(directory: directory)
        recorder.start(metadata: metadata())
        let held = HeldDiagnosticProbe()
        let monitor = AppHangMonitor(recorder: recorder,
            configuration: .init(tickInterval: 0.025, threshold: 0.15, maximumTickGap: 2, checkpointInterval: 0.05),
            probe: { held.submit($0) }, sampler: { id in
                .init(id: id, time: .now, outcome: .captured, exitStatus: 0, text: "Call graph:\n test waiting")
            })
        monitor.start()
        defer { monitor.stop(); recorder.finish(timeout: 1) }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var detected: DiagnosticHistory?
        while ProcessInfo.processInfo.systemUptime < deadline {
            let history = await recorder.history()
            if history.sessions.first?.samples.count == 1 { detected = history; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let session = try XCTUnwrap(detected?.sessions.first)
        XCTAssertEqual(session.entries.filter { $0.kind == .mainThreadUnresponsive }.count, 1)
        XCTAssertEqual(held.pendingCount, 1, "a stuck main run loop must not accumulate probe blocks")
        held.release()
        var recovered = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let history = await recorder.history()
            if history.sessions.first?.entries.contains(where: { $0.kind == .mainThreadRecovered }) == true {
                recovered = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(recovered)
    }
}

final class MainThreadWatchdogTests: XCTestCase {
    func testDetectsOnceAndRecordsDurationOnRecovery() throws {
        var watchdog = MainThreadWatchdog(now: 0)
        XCTAssertEqual(watchdog.tick(at: 0), [.probe(1)])
        for second in 1...4 { XCTAssertTrue(watchdog.tick(at: Double(second)).isEmpty) }
        XCTAssertEqual(watchdog.tick(at: 5), [.unresponsive(5)])
        XCTAssertTrue(watchdog.tick(at: 6).isEmpty)
        XCTAssertEqual(watchdog.acknowledge(1, at: 6), [.recovered(6)])
        XCTAssertEqual(watchdog.tick(at: 7), [.probe(2)])
        XCTAssertNil(watchdog.acknowledge(1, at: 7.1))
        XCTAssertEqual(watchdog.lastResponse, 6)
        XCTAssertEqual(watchdog.acknowledge(2, at: 7.1), [])
    }

    func testSchedulerGapIsNotBlamedOnMainThread() {
        var watchdog = MainThreadWatchdog(now: 0)
        XCTAssertEqual(watchdog.tick(at: 0), [.probe(1)])
        XCTAssertEqual(watchdog.tick(at: 30), [.watchdogDelayed(30), .probe(3)])
        XCTAssertEqual(watchdog.lastResponse, 0, "a scheduler gap is not a main-thread acknowledgment")
        XCTAssertNil(watchdog.acknowledge(1, at: 30.1))
        XCTAssertEqual(watchdog.acknowledge(3, at: 30.1), [])
        XCTAssertEqual(watchdog.tick(at: 31), [.probe(4)])
        // The queued main callback can run before the watchdog after waking.
        XCTAssertEqual(watchdog.acknowledge(4, at: 60), [.watchdogDelayed(29)])
    }

    func testSleepAndWakeInvalidatePendingCallbacks() {
        var watchdog = MainThreadWatchdog(now: 0)
        XCTAssertEqual(watchdog.tick(at: 0), [.probe(1)])
        watchdog.setSuspended(true, at: 1)
        XCTAssertTrue(watchdog.tick(at: 300).isEmpty)
        XCTAssertNil(watchdog.acknowledge(1, at: 300))
        watchdog.setSuspended(false, at: 301)
        XCTAssertEqual(watchdog.lastResponse, 0, "keep the actual last response time across sleep/wake")
        XCTAssertEqual(watchdog.tick(at: 301), [.probe(4)])
        XCTAssertNil(watchdog.acknowledge(1, at: 301.1))
        XCTAssertEqual(watchdog.acknowledge(4, at: 301.1), [])
    }

    func testLateReplyBetweenTicksRecordsDelayWithoutSamplingAnAlreadyRecoveredApp() {
        var watchdog = MainThreadWatchdog(now: 0)
        _ = watchdog.tick(at: 0)
        _ = watchdog.tick(at: 2)
        _ = watchdog.tick(at: 4)
        XCTAssertEqual(watchdog.acknowledge(1, at: 5.5), [.delayedResponse(5.5)])
        XCTAssertEqual(watchdog.tick(at: 6), [.probe(2)])
    }
}

private final class HeldDiagnosticProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [@Sendable ([String: Bool]) -> Void] = []
    private var released = false

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return replies.count }

    func submit(_ reply: @escaping @Sendable ([String: Bool]) -> Void) {
        lock.lock()
        if !released { replies.append(reply) }
        let deliver = released
        lock.unlock()
        if deliver { reply(["eventTapActive": true]) }
    }

    func release() {
        lock.lock()
        released = true
        let pending = replies
        replies.removeAll()
        lock.unlock()
        for reply in pending { reply(["eventTapActive": true]) }
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

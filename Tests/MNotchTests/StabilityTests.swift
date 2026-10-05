import AppKit
import Darwin
import Foundation
import ImageIO
import Network
import XCTest
@testable import MNotch

private actor HeldCalendarSource: CalendarDataSource {
    private var first: CheckedContinuation<CalendarWorker.Snapshot, Never>?
    private(set) var loads = 0

    func requestAccess() async -> Bool { true }

    func load(disabledCalendarIDs: [String], includeMonthDays: Bool,
              upcomingDays: Int, now: Date) async -> CalendarWorker.Snapshot {
        loads += 1
        if loads == 1 {
            return await withCheckedContinuation { first = $0 }
        }
        return snapshot("new")
    }

    func release() {
        first?.resume(returning: snapshot("old"))
        first = nil
    }

    private func snapshot(_ title: String) -> CalendarWorker.Snapshot {
        .init(today: [.init(id: title, title: title, start: .now, end: .now,
                           isAllDay: false, calendarID: "test", colorRed: 0,
                           colorGreen: 0, colorBlue: 0)],
              upcoming: [], calendars: [], monthEventDays: [])
    }
}

private actor HeldCalendarPermission: CalendarDataSource {
    private var first: CheckedContinuation<Bool, Never>?
    private(set) var requests = 0
    func requestAccess() async -> Bool {
        requests += 1
        if requests == 1 { return await withCheckedContinuation { first = $0 } }
        return true
    }
    func release() { first?.resume(returning: true); first = nil }
    func load(disabledCalendarIDs: [String], includeMonthDays: Bool,
              upcomingDays: Int, now: Date) async -> CalendarWorker.Snapshot {
        .init(today: [], upcoming: [], calendars: [], monthEventDays: [])
    }
}

final class StabilityTests: XCTestCase {
    func testCheckedIntegerRejectsRoundedIntMaxAndNonFiniteValues() {
        for value in [Double.nan, .infinity, -.infinity, Double(Int.max), 1e100] {
            XCTAssertNil(SafeNumeric.integer(value))
        }
        XCTAssertEqual(SafeNumeric.integer(Double(Int.min)), Int.min)
        XCTAssertEqual(SafeNumeric.integer(3.9), 3)
        XCTAssertNil(SafeNumeric.number("nan"))
        XCTAssertNil(SafeNumeric.number("inf"))
        XCTAssertNil(SafeNumeric.number(true))
    }

    func testMediaPayloadCannotTrapOnInvalidNumericStrings() throws {
        for value in ["nan", "inf", "-inf", "1e300", String(Double(Int.max))] {
            let data = try JSONSerialization.data(withJSONObject: [
                "title": "test", "shuffleMode": value, "repeatMode": value,
                "duration": value, "elapsedTime": value,
            ])
            let payload = try JSONDecoder().decode(MediaRemoteService.GetPayload.self, from: data)
            XCTAssertNil(payload.shuffleMode)
            XCTAssertNil(payload.repeatMode)
            XCTAssertEqual(MediaRemoteService.safeMediaSeconds(payload.duration), 0)
        }
    }

    @MainActor
    func testInvalidMediaDisplayTimesAndSeekDoNotCrash() {
        let media = MediaRemoteService()
        for value in [Double.nan, .infinity, -.infinity, -1, 1e100] {
            media.seek(to: value)
            XCTAssertEqual(media.playback.elapsedTime, 0)
            XCTAssertEqual(MediaExpandedView.timeString(value), "0:00")
        }
        XCTAssertEqual(MediaExpandedView.timeString(61), "1:01")
    }

    func testQuotaRejectsNonFiniteAndUnrepresentableMetadata() throws {
        for value in ["nan", "inf", "1e300", String(Double(Int.max))] {
            let data = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [
                "primary": ["usedPercent": 25, "windowDurationMins": value, "resetsAt": value],
            ]]])
            let window = try XCTUnwrap(CodexQuotaParser.snapshot(from: data)?.primary)
            XCTAssertNil(window.durationMinutes)
            XCTAssertNil(window.resetsAt)
        }
    }

    @MainActor
    func testDamagedPreferencesAndRuntimeAssignmentsFallBack() {
        let name = "com.mnotch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("nan", forKey: "pomo.work")
        defaults.set(Double.infinity, forKey: "battery.threshold")
        defaults.set(-10000, forKey: "tuning.width")
        defaults.set(true, forKey: "pomo.cycles")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.pomodoroWorkMinutes, 25)
        XCTAssertEqual(settings.batteryLowThreshold, 10)
        XCTAssertEqual(settings.notchWidthOffset, 0)
        XCTAssertEqual(settings.pomodoroCyclesPerLongBreak, 4)
        settings.pomodoroCyclesPerLongBreak = .nan
        settings.notchHeightOffset = .infinity
        settings.soundHUDDuration = -1
        XCTAssertEqual(settings.pomodoroCyclesPerLongBreak, 4)
        XCTAssertEqual(settings.notchHeightOffset, 0)
        XCTAssertEqual(settings.soundHUDDuration, 1.5)
        XCTAssertEqual(defaults.double(forKey: "pomo.cycles"), 4)
        settings.notchWidthOffset = 40
        XCTAssertEqual(settings.notchWidthOffset, 40)
    }

    func testEveryNumericPreferenceHasAnInRangeDefault() {
        for (key, rule) in PreferenceNumberPolicy.rules {
            XCTAssertTrue(rule.range.contains(rule.fallback), key)
            for raw in [Double.nan, .infinity, -.infinity, 1e200] {
                XCTAssertEqual(PreferenceNumberPolicy.value(raw, key: key, fallback: -999), rule.fallback, key)
            }
        }
    }

    func testSubprocessDrainsStdoutAndStderrTogether() async {
        let result = await SubprocessRunner.run(.init(executable: "/usr/bin/perl", arguments: ["-e",
            "print STDOUT 'x' x 120000; print STDERR 'y' x 120000;"], timeout: 3))
        XCTAssertEqual(result.completion, .exited(0))
        XCTAssertEqual(result.stdout.count, 120000)
        XCTAssertEqual(result.stderr.count, 120000)
    }

    func testSubprocessKillsAChildIgnoringTermination() async {
        let result = await SubprocessRunner.run(.init(executable: "/usr/bin/perl", arguments: ["-e",
            "$SIG{TERM} = 'IGNORE'; while (1) { sleep 1; }"], timeout: 0.15))
        XCTAssertEqual(result.completion, .timedOut)
        XCTAssertLessThan(result.elapsed, 2)
    }

    func testAppShutdownKillsRegisteredHelpersWithoutTaskCancellation() async {
        let lifecycle = SubprocessLifecycle()
        let cancellation = SubprocessCancellation(lifecycle: lifecycle)
        let request = SubprocessRunner.Request(executable: "/usr/bin/perl", arguments: ["-e",
            "$SIG{TERM} = 'IGNORE'; while (1) { sleep 1; }"], timeout: 30)
        let task = Task.detached { SubprocessRunner.runSync(request, cancellation: cancellation) }
        for _ in 0..<200 {
            if lifecycle.activeGroupCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(lifecycle.activeGroupCount, 1)
        lifecycle.beginShutdown()
        let result = await task.value
        XCTAssertEqual(result.completion, .cancelled)
        XCTAssertLessThan(result.elapsed, 2)
        XCTAssertEqual(lifecycle.activeGroupCount, 0)
        let later = SubprocessRunner.runSync(.init(executable: "/bin/sleep", arguments: ["30"]),
            cancellation: SubprocessCancellation(lifecycle: lifecycle))
        XCTAssertEqual(later.completion, .cancelled)
    }

    func testPreferredMediaRegistrationHasOneDeadlineAcrossRetries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appending(path: "blocked-adapter.pl")
        try "$SIG{TERM} = 'IGNORE'; sleep 30;".write(to: script, atomically: true, encoding: .utf8)
        let started = ProcessInfo.processInfo.systemUptime
        await MediaRemoteService.playWhenPreferredTargetIsReady(preferredBundleID: "test.player",
            paths: (script.path, "unused"), registrationTimeout: 0.1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }

    func testExcessivelyNestedAgentJSONFailsWithoutStackOverflow() {
        let input = String(repeating: "[", count: 2000) + "0" + String(repeating: "]", count: 2000)
        let data = Data((#"{"event":"Stop","tool_input":"# + input + "}").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentEvent.self, from: data))
    }

    func testDescendantHoldingPipeCannotDelayCompletion() async {
        let result = await SubprocessRunner.run(.init(executable: "/bin/sh", arguments: ["-c",
            "sleep 30 & echo $!; exit 0"], timeout: 2))
        XCTAssertEqual(result.completion, .exited(0))
        XCTAssertLessThan(result.elapsed, 1)
        let pid = Int32(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertNotNil(pid)
        if let pid {
            // A killed orphan may briefly remain a zombie until launchd reaps it.
            for _ in 0..<100 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testSubprocessOutputLimitIsGlobalAndExact() async {
        let result = await SubprocessRunner.run(.init(executable: "/usr/bin/perl", arguments: ["-e",
            "print STDOUT 'x' x 500000; print STDERR 'y' x 500000;"],
            timeout: 2, outputLimit: 32_000))
        XCTAssertEqual(result.completion, .outputLimit)
        XCTAssertLessThanOrEqual(result.stdout.count + result.stderr.count, 32_000)
        XCTAssertLessThan(result.elapsed, 2)
    }

    func testSubprocessCancellationBeforeAndAfterLaunch() async {
        let cancellation = SubprocessCancellation()
        cancellation.cancel()
        let before = SubprocessRunner.runSync(.init(executable: "/usr/bin/false"), cancellation: cancellation)
        XCTAssertEqual(before.completion, .cancelled)
        let task = Task { await SubprocessRunner.run(.init(executable: "/bin/sleep", arguments: ["30"])) }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        let after = await task.value
        XCTAssertEqual(after.completion, .cancelled)
        XCTAssertLessThan(after.elapsed, 2)
    }

    func testInvalidExecutableAndArgumentsFailWithoutTruncation() async {
        let missing = await SubprocessRunner.run(.init(executable: "/nonexistent/mnotch-test"))
        XCTAssertEqual(missing.completion, .launchFailed(ENOENT))
        let nul = await SubprocessRunner.run(.init(executable: "/bin/echo", arguments: ["valid\0unsafe"]))
        XCTAssertEqual(nul.completion, .launchFailed(EINVAL))
    }

    func testOneMailboxDeliveryCoalescesAHundredThousandHALCallbacks() {
        let mailbox = LatestValueMailbox<Int>()
        var jobs = 0
        for value in 0..<100000 where mailbox.submit(value) { jobs += 1 }
        XCTAssertEqual(jobs, 1)
        XCTAssertEqual(mailbox.take(), 99999)
        XCTAssertTrue(mailbox.submit(100000))
        XCTAssertEqual(mailbox.take(), 100000)
    }

    func testPipeStreamRejectsAnUnboundedCallbackBacklog() async {
        let stream = BoundedPipeStream(capacity: 2)
        stream.append(Data([1]))
        stream.append(Data([2]))
        stream.append(Data([3]))
        XCTAssertTrue(stream.overflowed)
        var received: [Data] = []
        for await chunk in stream.stream { received.append(chunk) }
        XCTAssertEqual(received, [Data([1]), Data([2])])
    }

    @MainActor
    func testCodexClosedStdinDoesNotKillTheAppWithSIGPIPE() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appending(path: "codex-test")
        try """
        #!/usr/bin/perl
        close STDIN;
        $| = 1;
        print '{"id":1,"result":{}}' . "\\n";
        sleep 3;
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let unavailable = expectation(description: "closed stdin degrades safely")
        unavailable.assertForOverFulfill = false
        let client = CodexQuotaClient(binary: binary)
        client.onUnavailable = { _ in unavailable.fulfill() }
        client.start()
        await fulfillment(of: [unavailable], timeout: 3)
        client.stop()
    }

    @MainActor
    func testCodexUnterminatedOversizedLineIsRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appending(path: "codex-test")
        try """
        #!/usr/bin/perl
        $| = 1;
        print 'x' x 2000000;
        sleep 3;
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let unavailable = expectation(description: "oversized output degrades safely")
        unavailable.assertForOverFulfill = false
        let client = CodexQuotaClient(binary: binary)
        client.onUnavailable = { _ in unavailable.fulfill() }
        client.start()
        await fulfillment(of: [unavailable], timeout: 3)
        client.stop()
    }

    @MainActor
    func testCodexStopKillsDescendantIgnoringTERMAndHoldingPipe() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appending(path: "codex-test")
        try """
        #!/usr/bin/perl
        $| = 1;
        my $child = fork();
        if (!$child) { $SIG{TERM} = 'IGNORE'; while (1) { sleep 1; } }
        print '{"id":1,"result":{}}' . "\\n";
        print '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25},"credits":{"balance":"' . $child . '"}}}}' . "\\n";
        sleep 30;
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let received = expectation(description: "fixture descendant PID received")
        let client = CodexQuotaClient(binary: binary)
        var descendant: pid_t?
        client.onSnapshot = { snapshot in
            descendant = snapshot.creditsBalance.flatMap(Int32.init)
            received.fulfill()
        }
        client.start()
        await fulfillment(of: [received], timeout: 3)
        client.stop()
        let pid = try XCTUnwrap(descendant)
        // Defensive cleanup also bounds a regression failure.
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        for _ in 0..<200 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    @MainActor
    func testCodexLateCallbacksAfter100StartStopsCannotPublish() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appending(path: "codex-test")
        try """
        #!/usr/bin/perl
        $SIG{PIPE} = 'IGNORE'; $| = 1;
        print '{"id":1,"result":{}}' . "\\n";
        print '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25}}}}' . "\\n";
        sleep 1;
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        weak var released: CodexQuotaClient?
        var snapshots = 0
        do {
            let client = CodexQuotaClient(binary: binary)
            released = client
            client.onSnapshot = { _ in snapshots += 1 }
            for _ in 0..<100 { client.start(); client.stop(); await Task.yield() }
        }
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(snapshots, 0)
        XCTAssertNil(released)
    }

    @MainActor
    func testCalendarAStalledOldQueryCannotAccumulateAcross100Restarts() async {
        let source = HeldCalendarSource()
        let calendar = CalendarService(worker: source)
        calendar.ensureStarted()
        for _ in 0..<100 {
            if await source.loads == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let initialLoads = await source.loads
        XCTAssertEqual(initialLoads, 1)
        for _ in 0..<100 {
            calendar.stop()
            calendar.ensureStarted()
            for _ in 0..<20 {
                if calendar.authorized { break }
                await Task.yield()
            }
            calendar.reload()
        }
        let whileStalled = await source.loads
        XCTAssertEqual(whileStalled, 1)
        await source.release()
        for _ in 0..<100 {
            if calendar.today.first?.title == "new" { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(calendar.today.first?.title, "new")
        let completedLoads = await source.loads
        XCTAssertEqual(completedLoads, 2)
        calendar.stop()
        XCTAssertTrue(calendar.today.isEmpty)
        XCTAssertFalse(calendar.authorized)
    }

    @MainActor
    func testCalendarLatePermissionCannotAccumulateAcross100Restarts() async {
        let source = HeldCalendarPermission()
        let calendar = CalendarService(worker: source)
        calendar.ensureStarted()
        for _ in 0..<100 {
            if await source.requests == 1 { break }
            await Task.yield()
        }
        for _ in 0..<100 { calendar.stop(); calendar.ensureStarted(); await Task.yield() }
        let pending = await source.requests
        XCTAssertEqual(pending, 1)
        XCTAssertFalse(calendar.authorized)
        await source.release()
        for _ in 0..<100 {
            if calendar.authorized { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(calendar.authorized)
        let completed = await source.requests
        XCTAssertEqual(completed, 2)
        calendar.stop()
    }

    func testRetentionCannotScheduleNaNOrDeleteOutsideTheShelf() {
        let directory = URL(fileURLWithPath: "/tmp/shelf-test")
        for path in ["/tmp/important.txt", "/tmp/shelf-test/../important.txt", "/tmp/shelf-test-other/file"] {
            XCTAssertNil(ShelfRetentionPolicy.deadline(0, path: path, directory: directory))
        }
        for value in [Double.nan, .infinity, -.infinity, 1e100] {
            XCTAssertNil(ShelfRetentionPolicy.deadline(value, path: "/tmp/shelf-test/file", directory: directory))
        }
        XCTAssertEqual(ShelfRetentionPolicy.deadline(0, path: "/tmp/shelf-test/file", directory: directory), 0)
    }

    func testShelfWorkerRefusesToTrashExternalFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let external = directory.appending(path: "important.txt")
        try Data("keep".utf8).write(to: external)
        let worker = ShelfFileWorker(directory: directory.appending(path: "shelf"))
        do { _ = try await worker.remove(external); XCTFail("external removal must fail") } catch {}
        do { _ = try await worker.clear([external]); XCTFail("external clear must fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: external), Data("keep".utf8))
    }

    func testFailedShelfBatchRollsBackCopiedFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "first.txt")
        try Data([1]).write(to: source)
        let worker = ShelfFileWorker(directory: directory.appending(path: "shelf"))
        do {
            _ = try await worker.add([source, directory.appending(path: "missing.txt")])
            XCTFail("batch with missing file must fail")
        } catch {}
        let snapshot = try await worker.list()
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testUnverifiedPrivateAPIsAreDisabledEvenWhenSymbolsMightExist() {
        for major in [15, 26, 27, 99] {
            let version = OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0)
            for integration in PrivateAPICompatibility.Integration.allCases {
                XCTAssertFalse(PrivateAPICompatibility.permits(integration, version: version))
            }
        }
        let verified: [PrivateAPICompatibility.Integration: Set<String>] = [.lockScreen: ["26.5"]]
        XCTAssertTrue(PrivateAPICompatibility.permits(.lockScreen,
            version: .init(majorVersion: 26, minorVersion: 5, patchVersion: 1), verified: verified))
        XCTAssertFalse(PrivateAPICompatibility.permits(.lockScreen,
            version: .init(majorVersion: 26, minorVersion: 6, patchVersion: 0), verified: verified))
    }

    func testDiagnosticBufferIsBoundedAndReportHasOnlyMetadata() throws {
        let buffer = DiagnosticBuffer(capacity: 2)
        for index in 0..<10 {
            buffer.append(.init(time: .now, component: .subprocess, code: .timedOut,
                                status: Int32(index), elapsed: 8))
        }
        XCTAssertEqual(buffer.snapshot().map(\.status), [8, 9])
        let report = AppDiagnostics.Report(schemaVersion: 1, createdAt: .now,
            appVersion: "test", appBuild: "1", macOSVersion: "27.0.0", architecture: "arm64",
            runtime: ["eventTapActive": false], events: buffer.snapshot())
        let json = try JSONSerialization.jsonObject(with: AppDiagnostics.encode(report)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "createdAt", "appVersion", "appBuild",
                                      "macOSVersion", "architecture", "runtime", "events"])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(Set(events[0].keys), ["time", "component", "code", "status", "elapsed"])
    }

    func testMalformedArtworkIsRejectedBeforeRendering() {
        XCTAssertNil(ArtworkDecoder.thumbnailData(Data("invalid image".utf8)))
        XCTAssertNil(ArtworkDecoder.thumbnailData(Data(repeating: 0, count: 12 * 1_024 * 1_024 + 1)))
    }

    func testValidArtworkIsDownsampledBeforeNSImageCreation() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 1024,
            bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let thumbnail = try XCTUnwrap(ArtworkDecoder.thumbnailData(data as Data))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let reduced = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(reduced.width, 512)
        XCTAssertLessThanOrEqual(reduced.height, 512)
    }

    @MainActor
    func testHUDNormalizesInvalidHardwareValues() {
        let model = NotchViewModel(geometry: .init(notchWidth: 185, notchHeight: 32, isPhysical: false))
        for value in [Double.nan, .infinity, -.infinity, -1, 1e100] {
            model.showHUD(.volume, value: value)
            XCTAssertTrue(model.hudValue.isFinite)
            XCTAssertTrue((0...1).contains(model.hudValue))
        }
    }

    @MainActor
    func testPomodoroTimerIsReleasedAfter100StartStopCycles() {
        weak var released: PomodoroService?
        do {
            let pomodoro = PomodoroService()
            released = pomodoro
            for _ in 0..<100 {
                pomodoro.start()
                pomodoro.pause()
                pomodoro.start()
                pomodoro.reset()
                XCTAssertFalse(pomodoro.isRunning)
                XCTAssertNil(pomodoro.endDate)
                XCTAssertFalse(pomodoro.isActive)
            }
        }
        XCTAssertNil(released)
    }

    @MainActor
    func testAgentListenerDoesNotRestoreResourcesAfter100Restarts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = AgentServer(directory: directory)
        for _ in 0..<100 {
            server.start()
            for _ in 0..<200 {
                if server.port != 0 { break }
                try? await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertNotEqual(server.port, 0)
            server.stop()
            XCTAssertEqual(server.port, 0)
            XCTAssertEqual(server.activeConnectionCount, 0)
        }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(server.port, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "agent-port").path))
    }

    @MainActor
    func testAgentStopClosesAnUnauthenticatedIncompleteConnection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = AgentServer(directory: directory)
        server.start()
        defer { server.stop() }
        for _ in 0..<200 {
            if server.port != 0 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: server.port))
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let ready = expectation(description: "connected")
        connection.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        connection.start(queue: .global())
        defer { connection.cancel() }
        await fulfillment(of: [ready], timeout: 2)
        for _ in 0..<200 {
            if server.activeConnectionCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(server.activeConnectionCount, 1)
        let ended = expectation(description: "peer closed")
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
            if complete || error != nil { ended.fulfill() }
        }
        server.stop()
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(server.activeConnectionCount, 0)
    }

    @MainActor
    func testAgentRejectsWrongTokenAndOversizedPayloadButAcceptsValidEvent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = AgentServer(directory: directory)
        server.start()
        defer { server.stop() }
        for _ in 0..<200 {
            if server.port != 0 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: server.port))
        let tokenURL = directory.appending(path: "agent-token")
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: tokenURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var delivered = 0
        server.onEvent = { _, _ in delivered += 1 }
        for payload in [Data(#"{"token":"wrong","event":{"event":"SessionStart"}}"#.utf8),
                        Data(repeating: 120, count: AgentServer.maximumPayloadBytes + 1),
                        try JSONSerialization.data(withJSONObject: ["token": token, "event": ["event": "SessionStart"]])] {
            let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            let ready = expectation(description: "fixture connected")
            connection.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
            connection.start(queue: .global())
            await fulfillment(of: [ready], timeout: 2)
            let closed = expectation(description: "fixture closed")
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                if complete || error != nil { closed.fulfill() }
            }
            connection.send(content: payload, completion: .contentProcessed { _ in })
            await fulfillment(of: [closed], timeout: 2)
            connection.cancel()
        }
        XCTAssertEqual(delivered, 1)
    }

    @MainActor
    func testAgentStopEventClearsPendingApprovalAndBoundsSessions() throws {
        let monitor = AgentMonitorService()
        var resolved = 0
        monitor.onRequestResolved = { resolved += 1 }
        let decoder = JSONDecoder()
        let request = try decoder.decode(AgentEvent.self, from: Data(#"{"event":"PermissionRequest","session_id":"s","tool_name":"Bash"}"#.utf8))
        monitor.handle(request, requestID: 1)
        XCTAssertTrue(monitor.hasPendingRequest)
        let stop = try decoder.decode(AgentEvent.self, from: Data(#"{"event":"Stop","session_id":"s"}"#.utf8))
        monitor.handle(stop, requestID: nil)
        XCTAssertFalse(monitor.hasPendingRequest)
        XCTAssertEqual(resolved, 1)
        for index in 0..<125 {
            let event = try decoder.decode(AgentEvent.self, from: Data("{\"event\":\"SessionStart\",\"session_id\":\"s\(index)\"}".utf8))
            monitor.handle(event, requestID: nil)
        }
        XCTAssertEqual(monitor.sessions.count, 100)
        monitor.stop()
        XCTAssertTrue(monitor.sessions.isEmpty)
    }

    func testHookConfigurationRejectsCorruptionWithoutChangingBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "hooks.json")
        XCTAssertNil(try HookConfiguration.read(file))
        for source in ["bad JSON", "[]", #"{"hooks":"wrong type"}"#,
                       #"{"hooks":{"Stop":[{"hooks":"wrong type"}]}}"#] {
            let original = Data(source.utf8)
            try original.write(to: file)
            XCTAssertThrowsError(try HookConfiguration.read(file))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
        try Data(repeating: 32, count: 2 * 1_024 * 1_024 + 1).write(to: file)
        XCTAssertThrowsError(try HookConfiguration.read(file))
        let valid = Data(#"{"hooks":{"Stop":[{"hooks":[{"command":"keep"}]}]},"other":true}"#.utf8)
        try valid.write(to: file)
        XCTAssertNotNil(try HookConfiguration.read(file))
    }

    func testFailedScriptDeploymentPreservesWorkingScript() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "relay.pl")
        let original = Data("working script".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try HookConfiguration.deploy(directory.appending(path: "missing"), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testDiagnosticRunCannotStartUpdater() {
        let policy = AppUpdateRuntimePolicy(isRunningTests: false, isDebugBuild: false,
            environment: ["MNOTCH_DIAGNOSTIC_RUN": "1", "MNOTCH_ENABLE_UPDATES": "1"])
        XCTAssertFalse(policy.updatesAreEnabled)
    }

    func testBoundedFileReadRejectsOversizedAndNonRegularInput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "oversized")
        try Data(repeating: 1, count: 1001).write(to: file)
        XCTAssertThrowsError(try BoundedFileReader.read(file, limit: 1000))
        XCTAssertThrowsError(try BoundedFileReader.read(directory, limit: 1000))
        XCTAssertEqual(try BoundedFileReader.read(file, limit: 1001).count, 1001)
    }

    func testShellQuotingRoundTripsMetacharactersWithoutExecution() async {
        let input = "apostrophe' newline\n$(false) `false` ; & | \\\""
        let result = await SubprocessRunner.run(.init(executable: "/bin/sh",
            arguments: ["-c", "printf %s " + HookConfiguration.shellQuote(input)]))
        XCTAssertEqual(result.completion, .exited(0))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), input)
    }

    @MainActor
    func testCodexUninstallPreservesCustomCommandMentioningRelay() throws {
        for command in ["echo mnotch-relay.pl codex", "/usr/bin/perl '/custom/mnotch-relay.pl' codex"] {
            let root: [String: Any] = ["hooks": ["Stop": [["hooks": [["command": command]]]]]]
            let result = CodexHookInstaller.uninstalling(from: root)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: result, options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: root, options: .sortedKeys))
        }
    }

    @MainActor
    func testClaudeMigrationPreservesCustomStatusLineMentioningLegacyHelper() throws {
        for command in ["echo mnotch-claude-statusline.pl", "/usr/bin/perl '/custom/mnotch-claude-statusline.pl'"] {
            let root: [String: Any] = ["statusLine": ["type": "command", "command": command, "padding": 7]]
            let result = ClaudeHookInstaller.restoringRetiredQuotaBridge(in: root, backupData: Data("{}".utf8))
            XCTAssertFalse(result.restored)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: result.root, options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: root, options: .sortedKeys))
        }
    }

    @MainActor
    func testClaudeMigrationPreservesConfigurationWhenBackupIsInvalid() throws {
        let command = "/usr/bin/perl '/tmp/mnotch-claude-statusline.pl'"
        let root: [String: Any] = ["statusLine": ["type": "command", "command": command], "theme": "dark"]
        for data in [Data("broken JSON".utf8), Data("[]".utf8), Data(repeating: 32, count: 2 * 1_024 * 1_024 + 1)] {
            let result = ClaudeHookInstaller.restoringRetiredQuotaBridge(in: root, backupData: data, legacyCommand: command)
            XCTAssertFalse(result.restored)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: result.root, options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: root, options: .sortedKeys))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mnotch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

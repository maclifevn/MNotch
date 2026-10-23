import XCTest
@testable import MNotch

@MainActor
final class UpdateIntegrationTests: XCTestCase {
    func testInstallWaitsForWorkWhileBlockingNewIntake() async throws {
        var busy = true, paused = false
        let coordinator = UpdateInstallationCoordinator(dependencies: .init(
            pause: { paused = true }, resume: { paused = false }, hasActiveWork: { busy }
        ))
        let task = Task { await coordinator.prepare() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(coordinator.state, .waiting)
        XCTAssertTrue(paused)
        busy = false
        let ready = await task.value
        XCTAssertTrue(ready)
        XCTAssertEqual(coordinator.state, .prepared)
        XCTAssertTrue(paused, "intake stays paused until Sparkle quits or aborts")
        coordinator.cancel()
        XCTAssertFalse(paused)
    }

    func testCancelResumesFilesAndOldPreparationCannotInstall() async throws {
        var paused = false
        let coordinator = UpdateInstallationCoordinator(dependencies: .init(
            pause: { paused = true }, resume: { paused = false }, hasActiveWork: { true }
        ))
        let task = Task { await coordinator.prepare() }
        try await Task.sleep(for: .milliseconds(20))
        coordinator.cancel()
        XCTAssertFalse(paused)
        let ready = await task.value
        XCTAssertFalse(ready)
        XCTAssertEqual(coordinator.state, .active)
    }

    func testTaskCancellationUnpausesFileTray() async throws {
        var paused = false
        let coordinator = UpdateInstallationCoordinator(dependencies: .init(
            pause: { paused = true }, resume: { paused = false }, hasActiveWork: { true }
        ))
        let task = Task { await coordinator.prepare() }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let ready = await task.value
        XCTAssertFalse(ready)
        XCTAssertFalse(paused)
        XCTAssertEqual(coordinator.state, .active)
    }

    func testCancelledRunCannotResumeOrPrepareNewRun() async throws {
        var busy = true, pauses = 0, resumes = 0
        let coordinator = UpdateInstallationCoordinator(dependencies: .init(
            pause: { pauses += 1 }, resume: { resumes += 1 }, hasActiveWork: { busy }
        ))
        let old = Task { await coordinator.prepare() }
        try await Task.sleep(for: .milliseconds(20))
        coordinator.cancel()
        let new = Task { await coordinator.prepare() }
        try await Task.sleep(for: .milliseconds(20))
        let oldReady = await old.value
        XCTAssertFalse(oldReady)
        XCTAssertEqual(coordinator.state, .waiting)
        XCTAssertEqual(resumes, 1)
        busy = false
        let newReady = await new.value
        XCTAssertTrue(newReady)
        XCTAssertEqual(pauses, 2)
        let repeated = await coordinator.prepare()
        XCTAssertTrue(repeated)
        XCTAssertEqual(pauses, 2)
        coordinator.cancel()
    }

    func testLiveDragSessionMustFinishBeforeUpdate() {
        ShelfOutgoingDragState.begin()
        defer { ShelfOutgoingDragState.end() }
        XCTAssertTrue(ShelfOutgoingDragState.hasLiveSession)
        ShelfOutgoingDragState.end()
        XCTAssertFalse(ShelfOutgoingDragState.hasLiveSession)
    }
}

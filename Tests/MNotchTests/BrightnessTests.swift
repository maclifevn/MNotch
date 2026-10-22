import CoreGraphics
import Foundation
import XCTest
@testable import MNotch

@MainActor
final class BrightnessTests: XCTestCase {
    func testBrightnessProbesEverySupportedOSWithoutAHostAllowlist() {
        // Previously only one model / patch / build was allowed, so working
        // brightness keys on every other Mac silently fell through to macOS.
        for major in [15, 26, 27, 99] {
            for patch in [0, 1, 2, 99] {
                let version = OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: patch)
                XCTAssertTrue(PrivateAPICompatibility.permits(.displayBrightness, version: version))
                for integration in [PrivateAPICompatibility.Integration.keyboardBacklight, .lockScreen] {
                    XCTAssertFalse(PrivateAPICompatibility.permits(integration, version: version))
                }
            }
        }
        XCTAssertFalse(PrivateAPICompatibility.permits(.displayBrightness,
            version: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0)))
    }

    func testCapabilityFailureKeepsNativeKeysUntilTheDisplayBecomesAvailable() async {
        let hardware = TestBrightnessHardware()
        hardware.update { $0.readFailure = .unavailable }
        let service = BrightnessService(hardware: hardware)
        service.start()
        defer { service.stop() }
        await eventually { hardware.snapshot.completedReads == 1 && !service.isUpdating }
        XCTAssertTrue(service.isRunning)
        XCTAssertTrue(service.hasFailure)
        XCTAssertFalse(service.available)
        _ = service.step(up: true, fine: false)
        XCTAssertTrue(hardware.snapshot.writes.isEmpty)

        hardware.update { $0.readFailure = nil; $0.value = 0.75 }
        service.refresh()
        await eventually { service.available }
        XCTAssertFalse(service.hasFailure)
        XCTAssertEqual(service.step(up: false, fine: false), 0.6875)
        await eventually { hardware.snapshot.value == 0.6875 && !service.isUpdating }
    }

    func testSlowReadMustResampleBeforeTakingKeysFromMacOS() async {
        let hardware = TestBrightnessHardware()
        let clock = BrightnessTestClock()
        let release = DispatchSemaphore(value: 0)
        hardware.update { $0.blockRead = release }
        let service = BrightnessService(hardware: hardware, clock: { clock.now })
        service.start()
        defer { service.stop() }
        await eventually { hardware.snapshot.reads == 1 }
        clock.advance(3)
        // Native keys may have adjusted the display while the API was stuck.
        hardware.update { $0.value = 0.75 }
        release.signal()
        await eventually { service.available && service.brightness == 0.75 }
        XCTAssertEqual(hardware.snapshot.reads, 2)
        XCTAssertTrue(hardware.snapshot.writes.isEmpty)
    }

    func testUnpermittedServiceDoesNotTouchHardware() async {
        let hardware = TestBrightnessHardware()
        let service = BrightnessService(hardware: hardware, permitted: false)
        service.start()
        service.startObserving()
        service.refresh()
        _ = service.step(up: true, fine: false)
        await Task.yield()
        XCTAssertFalse(service.available)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(hardware.snapshot.reads, 0)
        XCTAssertTrue(hardware.snapshot.writes.isEmpty)
    }

    func testKeysStayNativeBeforeTheInitialSampleAndAfterStop() async {
        let hardware = TestBrightnessHardware()
        let release = DispatchSemaphore(value: 0)
        hardware.update { $0.blockRead = release }
        let service = BrightnessService(hardware: hardware)
        service.start()
        await eventually { hardware.snapshot.reads == 1 }
        XCTAssertFalse(service.available)
        _ = service.step(up: true, fine: false)
        XCTAssertTrue(hardware.snapshot.writes.isEmpty)
        release.signal()
        await eventually { service.available }
        service.stop()
        _ = service.step(up: true, fine: false)
        XCTAssertFalse(service.available)
        XCTAssertFalse(service.hasFailure)
        XCTAssertTrue(hardware.snapshot.writes.isEmpty)
    }

    func testLateWriteFailureCannotBeClearedByASuccessfulRead() async {
        let hardware = TestBrightnessHardware()
        let clock = BrightnessTestClock()
        let service = BrightnessService(hardware: hardware, clock: { clock.now })
        service.start()
        defer { service.stop() }
        await eventually { service.available }
        let release = DispatchSemaphore(value: 0)
        hardware.update { $0.blockWrite = release; $0.writeFailure = .writeFailed(-50) }
        _ = service.step(up: true, fine: false)
        await eventually { hardware.snapshot.writes.count == 1 }
        clock.advance(3)
        release.signal()
        await eventually { service.hasFailure && !service.isUpdating }
        service.refresh()
        await eventually { service.isResponsive }
        XCTAssertFalse(service.available)
        XCTAssertTrue(service.hasFailure)
        _ = service.step(up: true, fine: false)
        XCTAssertEqual(hardware.snapshot.writes.count, 1)
    }

    func testRepeatedStepsCoalesceWithoutRollingBackTheHUD() async {
        let hardware = TestBrightnessHardware()
        let service = BrightnessService(hardware: hardware, permitted: true)
        service.start()
        defer { service.stop() }
        await eventually { service.available }
        let release = DispatchSemaphore(value: 0)
        hardware.update { $0.blockWrite = release }
        XCTAssertEqual(service.step(up: true, fine: false), 0.5625)
        await eventually { hardware.snapshot.writes.count == 1 }
        for index in 0..<1000 { _ = service.step(up: index % 2 == 0, fine: true) }
        XCTAssertEqual(service.step(up: true, fine: false), 0.625)
        XCTAssertEqual(hardware.snapshot.writes.count, 1)
        XCTAssertEqual(service.brightness, 0.625)
        release.signal()
        await eventually { hardware.snapshot.value == 0.625 && !service.isUpdating }
        XCTAssertEqual(service.brightness, 0.625)
        XCTAssertEqual(hardware.snapshot.writes.count, 2)
        XCTAssertTrue(hardware.snapshot.writes.allSatisfy { $0.display == 1 })
    }

    func testLeaseExpiryDropsPendingStepsInsteadOfReplayingThemAfterAStall() async {
        let hardware = TestBrightnessHardware()
        let clock = BrightnessTestClock()
        let service = BrightnessService(hardware: hardware, permitted: true, clock: { clock.now })
        service.start()
        defer { service.stop() }
        await eventually { service.available }
        let release = DispatchSemaphore(value: 0)
        hardware.update { $0.blockWrite = release }
        _ = service.step(up: true, fine: false)
        await eventually { hardware.snapshot.writes.count == 1 }
        _ = service.step(up: true, fine: false)
        clock.advance(3)
        XCTAssertFalse(service.available)
        service.refresh()
        for _ in 0..<1000 { _ = service.step(up: true, fine: false) }
        release.signal()
        await eventually { service.available }
        XCTAssertEqual(hardware.snapshot.writes.count, 1)
        XCTAssertEqual(service.brightness, 0.5625)
    }

    func testOneBlockedReadStaysSingleFlightAcrossOneHundredRestarts() async {
        let hardware = TestBrightnessHardware()
        let release = DispatchSemaphore(value: 0)
        hardware.update { $0.blockRead = release }
        let service = BrightnessService(hardware: hardware, permitted: true)
        service.start()
        await eventually { hardware.snapshot.reads == 1 }
        for _ in 0..<100 {
            service.stop()
            service.start()
            service.startObserving()
            service.refresh()
        }
        defer { service.stop() }
        XCTAssertFalse(service.available)
        XCTAssertEqual(hardware.snapshot.reads, 1)
        hardware.update { $0.value = 0.75 }
        release.signal()
        await eventually { service.available && service.brightness == 0.75 }
        XCTAssertEqual(hardware.snapshot.reads, 2)
        XCTAssertTrue(hardware.snapshot.writes.isEmpty)
    }

    func testStoppedServiceCanDeallocateWhileHardwareIsBlocked() async {
        let hardware = TestBrightnessHardware()
        let release = DispatchSemaphore(value: 0)
        hardware.update { $0.blockRead = release }
        var service: BrightnessService? = BrightnessService(hardware: hardware, permitted: true)
        weak var owner = service
        service?.start()
        await eventually { hardware.snapshot.reads == 1 }
        service?.stop()
        service = nil
        XCTAssertNil(owner)
        release.signal()
        await eventually { hardware.snapshot.completedReads == 1 }
    }

    func testExternalChangesNotifyButOwnWritesDoNotEcho() async {
        let hardware = TestBrightnessHardware()
        let service = BrightnessService(hardware: hardware, permitted: true)
        var updates: [Double] = []
        service.onChanged = { updates.append($0) }
        service.start()
        defer { service.stop() }
        await eventually { service.available }
        XCTAssertTrue(updates.isEmpty)
        hardware.update { $0.value = 0.25 }
        service.refresh()
        await eventually { updates == [0.25] }
        XCTAssertEqual(service.step(up: true, fine: false), 0.3125)
        await eventually { hardware.snapshot.value == 0.3125 && !service.isUpdating }
        let reads = hardware.snapshot.reads
        service.refresh()
        await eventually { hardware.snapshot.reads > reads && !service.isUpdating }
        XCTAssertEqual(updates, [0.25])
    }

    func testInvalidSamplesWriteFailureAndDisplayChangeReleaseControl() async {
        let hardware = TestBrightnessHardware()
        hardware.update { $0.value = .nan }
        let service = BrightnessService(hardware: hardware, permitted: true)
        service.start()
        defer { service.stop() }
        await eventually { hardware.snapshot.completedReads == 1 && !service.isUpdating }
        XCTAssertFalse(service.available)
        hardware.update { $0.value = 0.5 }
        service.refresh()
        await eventually { service.available }
        hardware.update { $0.writeFailure = .writeFailed(-50) }
        _ = service.step(up: true, fine: false)
        await eventually { !service.isResponsive }
        hardware.update { $0.writeFailure = nil }
        service.refresh()
        await eventually { service.isResponsive }
        XCTAssertFalse(service.available) // Read success alone cannot approve writes.
        service.stop()
        service.start()
        await eventually { service.available }
        hardware.update { $0.display = 2 }
        _ = service.step(up: true, fine: false)
        await eventually { !service.isResponsive }
        XCTAssertEqual(hardware.snapshot.value, 0.5)
        service.refresh()
        await eventually { service.available }
        _ = service.step(up: true, fine: false)
        await eventually { hardware.snapshot.value == 0.5625 }
        XCTAssertEqual(hardware.snapshot.writes.last?.display, 2)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Brightness state did not settle", file: file, line: line)
    }
}

private final class BrightnessTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ delta: TimeInterval) { lock.withLock { value += delta } }
}

private final class TestBrightnessHardware: BrightnessHardwareAccess, @unchecked Sendable {
    struct Write { let value: Double; let display: CGDirectDisplayID }
    struct State {
        var value = 0.5
        var display: CGDirectDisplayID = 1
        var reads = 0
        var completedReads = 0
        var writes: [Write] = []
        var readFailure: BrightnessHardwareFailure?
        var writeFailure: BrightnessHardwareFailure?
        var blockRead: DispatchSemaphore?
        var blockWrite: DispatchSemaphore?
    }
    private let lock = NSLock()
    private var state = State()
    var snapshot: State { lock.withLock { state } }
    func update(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }

    func read() -> Result<BrightnessSnapshot, BrightnessHardwareFailure> {
        let (result, block): (Result<BrightnessSnapshot, BrightnessHardwareFailure>, DispatchSemaphore?) = lock.withLock {
            state.reads += 1
            let block = state.blockRead
            state.blockRead = nil
            if let failure = state.readFailure { return (.failure(failure), block) }
            return (.success(.init(value: state.value, displayID: state.display)), block)
        }
        block?.wait()
        lock.withLock { state.completedReads += 1 }
        return result
    }

    func write(_ value: Double, displayID: CGDirectDisplayID) -> Result<BrightnessSnapshot, BrightnessHardwareFailure> {
        let block = lock.withLock {
            state.writes.append(.init(value: value, display: displayID))
            let block = state.blockWrite
            state.blockWrite = nil
            return block
        }
        block?.wait()
        return lock.withLock {
            guard displayID == state.display else { return .failure(.displayChanged) }
            if let failure = state.writeFailure { return .failure(failure) }
            state.value = value
            return .success(.init(value: value, displayID: displayID))
        }
    }
}

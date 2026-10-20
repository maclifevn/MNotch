import CoreAudio
import Foundation
import XCTest
@testable import MNotch

@MainActor
final class AudioOutputTests: XCTestCase {
    func testUnavailableOutputsNeverTakeOverVolumeKeysAndRecoverWithoutRestart() async {
        let hardware = TestAudioHardware()
        hardware.update { $0.devices[10]?.supportsVolume = false }
        let audio = makeService(hardware)
        audio.start()
        defer { audio.stop() }
        await eventually { audio.isResponsive }
        XCTAssertFalse(audio.canSetVolume)
        XCTAssertTrue(audio.canSetMute)

        // The default-change notification is deliberately omitted.
        hardware.update { $0.defaultDevice = 20; $0.devices[20] = .init() }
        audio.refresh()
        await eventually { audio.canSetVolume }
        audio.setVolume(0.75)
        await eventually { hardware.snapshot.devices[20]?.volume == 0.75 }
        XCTAssertTrue(hardware.snapshot.writes.allSatisfy { $0.object == 20 })
    }

    func testWriteRechecksDefaultInsteadOfUsingTheCachedDevice() async {
        let hardware = TestAudioHardware()
        let audio = makeService(hardware)
        audio.start()
        defer { audio.stop() }
        await eventually { audio.canSetVolume }
        hardware.update { $0.defaultDevice = 20; $0.devices[20] = .init() }
        audio.setVolume(0.25)
        await eventually { hardware.snapshot.writes.count == 1 }
        XCTAssertEqual(hardware.snapshot.writes.first?.object, 20)
        XCTAssertEqual(hardware.snapshot.devices[10]?.volume, 0.5)
    }

    func testMissingDefaultClearsControlAndCanRecoverOnTheSameDeviceID() async {
        let hardware = TestAudioHardware()
        let audio = makeService(hardware)
        audio.start()
        defer { audio.stop() }
        await eventually { audio.canSetVolume }
        hardware.update { $0.defaultStatus = kAudioHardwareBadObjectError }
        audio.refresh()
        await eventually { !audio.canSetVolume && !audio.canSetMute }

        hardware.update { $0.defaultStatus = noErr }
        audio.refresh()
        await eventually { audio.canSetVolume && audio.canSetMute }
        XCTAssertEqual(hardware.snapshot.addCounts[kAudioDevicePropertyMute], 2)
    }

    func testWriteFailureReleasesKeysDespiteSuccessfulSubsequentReads() async {
        let hardware = TestAudioHardware()
        let audio = makeService(hardware)
        audio.start()
        defer { audio.stop() }
        await eventually { audio.canSetVolume }
        hardware.update { $0.devices[10]?.writeStatus = kAudioHardwareIllegalOperationError }
        audio.setVolume(0.8)
        await eventually { !audio.canSetVolume && audio.volume == 0.5 }
        audio.refresh()
        await eventually { hardware.snapshot.defaultReads >= 3 }
        XCTAssertFalse(audio.canSetVolume)
        XCTAssertTrue(audio.canSetMute)
        XCTAssertTrue(AppDiagnostics.buffer.snapshot().contains {
            $0.component == .audio && $0.code == .writeFailed
                && $0.status == kAudioHardwareIllegalOperationError
        })

        // A route change clears the failed-write latch for the new output.
        hardware.update { $0.defaultDevice = 20; $0.devices[20] = .init() }
        audio.refresh()
        await eventually { audio.canSetVolume }
    }

    func testMuteFailureDoesNotDisableUnmutedVolumeControl() async {
        let hardware = TestAudioHardware()
        let audio = makeService(hardware)
        audio.start()
        defer { audio.stop() }
        await eventually { audio.canSetMute }
        hardware.update { $0.devices[10]?.writeStatus = kAudioHardwareIllegalOperationError }
        audio.setMuted(true)
        await eventually { !audio.canSetMute && !audio.muted }
        XCTAssertTrue(audio.canSetVolume)
    }

    func testServiceResetRebuildsListenersEvenWhenDeviceIDIsUnchanged() async {
        let hardware = TestAudioHardware()
        let audio = makeService(hardware)
        audio.start()
        defer { audio.stop() }
        await eventually { audio.canSetVolume }
        hardware.update { $0.devices[10]?.volume = 0.25 }
        hardware.emit(kAudioHardwarePropertyServiceRestarted)
        await eventually { audio.volume == 0.25 }
        XCTAssertEqual(hardware.snapshot.addCounts[kAudioHardwarePropertyDefaultOutputDevice], 2)
        XCTAssertEqual(hardware.snapshot.addCounts[kAudioHardwarePropertyServiceRestarted], 2)
        XCTAssertEqual(hardware.snapshot.addCounts[kAudioDevicePropertyMute], 2)
        XCTAssertTrue(audio.canSetVolume)
    }

    func testStalledHALExpiresControlLeaseWithoutBlockingTheMainActor() async {
        let hardware = TestAudioHardware()
        var clockOffset: TimeInterval = 0
        let audio = AudioOutputService(hal: AudioHALWorker(hardware: hardware, recoveryInterval: nil),
            now: { ProcessInfo.processInfo.systemUptime + clockOffset })
        audio.start()
        defer { audio.stop() }
        await eventually { audio.canSetVolume }

        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        hardware.update { $0.blockNextDefaultRead = release; $0.devices[10]?.volume = 0.75 }
        audio.refresh()
        await eventually { hardware.snapshot.readBlocked }
        clockOffset = 4
        XCTAssertTrue(audio.isRunning)
        XCTAssertFalse(audio.isResponsive)
        XCTAssertFalse(audio.canSetVolume)
        XCTAssertFalse(audio.canSetMute)
        release.signal()
        clockOffset = 0
        await eventually { audio.volume == 0.75 && audio.canSetVolume }
    }

    func testPeriodicRecoveryFindsAnOutputWithoutAnyNotifications() async {
        let hardware = TestAudioHardware()
        hardware.update { $0.defaultDevice = AudioObjectID(kAudioObjectUnknown) }
        let audio = AudioOutputService(hal: AudioHALWorker(hardware: hardware, recoveryInterval: 0.02))
        audio.start()
        defer { audio.stop() }
        await eventually { audio.isResponsive }
        XCTAssertFalse(audio.canSetVolume)
        hardware.update { $0.defaultDevice = 10 }
        await eventually { audio.canSetVolume }
    }

    func testMainScalarWorksWhenVirtualVolumeIsUnsupported() async {
        let hardware = TestAudioHardware()
        hardware.update { $0.devices[10]?.virtualVolume = false }
        let audio = makeService(hardware)
        audio.start()
        defer { audio.stop() }
        await eventually { audio.canSetVolume }
        audio.setVolume(0.75)
        await eventually { hardware.snapshot.writes.count == 1 }
        XCTAssertEqual(hardware.snapshot.writes.first?.selector, kAudioDevicePropertyVolumeScalar)
    }

    func testAsyncHALWritesDoNotImmediatelyRestoreTheOldVolume() async {
        let hardware = TestAudioHardware()
        hardware.update { $0.deferWrites = true }
        let worker = AudioHALWorker(hardware: hardware, recoveryInterval: nil)
        let mailbox = LatestValueMailbox<AudioHALWorker.Snapshot>()
        worker.start { _ = mailbox.submit($0) }
        defer { worker.stop() }
        var latest: AudioHALWorker.Snapshot?
        await eventually { latest = mailbox.take(); return latest != nil }
        XCTAssertEqual(latest?.volume, 0.5)
        worker.setVolume(0.75)
        await eventually { latest = mailbox.take(); return latest != nil }
        XCTAssertEqual(latest?.volume, 0.75)
        XCTAssertEqual(hardware.snapshot.devices[10]?.volume, 0.5)
    }

    func testReadOnlyAndFailedReadsDoNotTakeOverKeys() async {
        let hardware = TestAudioHardware()
        hardware.update { $0.devices[10]?.settable = false }
        let audio = makeService(hardware)
        audio.start()
        defer { audio.stop() }
        await eventually { audio.isResponsive }
        XCTAssertFalse(audio.canSetVolume)
        XCTAssertFalse(audio.canSetMute)
        hardware.update { $0.devices[10]?.settable = true; $0.devices[10]?.readStatus = kAudioHardwareBadObjectError }
        audio.refresh()
        await eventually { hardware.snapshot.defaultReads >= 2 }
        XCTAssertFalse(audio.canSetVolume)
        XCTAssertFalse(audio.canSetMute)
        hardware.update { $0.devices[10]?.readStatus = noErr }
        audio.refresh()
        await eventually { audio.canSetVolume && audio.canSetMute }
    }

    func testStoppedServiceCannotBeReenabledByALateHALResult() async {
        let hardware = TestAudioHardware()
        let audio = makeService(hardware)
        audio.start()
        await eventually { audio.canSetVolume }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        hardware.update { $0.blockNextDefaultRead = release }
        audio.refresh()
        await eventually { hardware.snapshot.readBlocked }
        audio.stop()
        release.signal()
        await eventually { hardware.snapshot.registrations.isEmpty }
        XCTAssertFalse(audio.isResponsive)
        XCTAssertFalse(audio.canSetVolume)
        audio.start()
        defer { audio.stop() }
        await eventually { audio.canSetVolume }
    }

    func testDiagnosticFailuresSurviveSuccessfulMediaPolling() {
        let buffer = DiagnosticBuffer(capacity: 3)
        buffer.append(.init(time: .now, component: .audio, code: .writeFailed, status: -50, elapsed: nil))
        for _ in 0..<1000 {
            buffer.append(.init(time: .now, component: .media, code: .exited, status: 0, elapsed: 0.05))
        }
        XCTAssertEqual(buffer.snapshot().count, 3)
        XCTAssertEqual(buffer.snapshot().first?.code, .writeFailed)
        let errorsOnly = DiagnosticBuffer(capacity: 1)
        errorsOnly.append(.init(time: .now, component: .audio, code: .readFailed, status: -50, elapsed: nil))
        errorsOnly.append(.init(time: .now, component: .media, code: .exited, status: 0, elapsed: 0.05))
        XCTAssertEqual(errorsOnly.snapshot().first?.code, .readFailed)
    }

    private func makeService(_ hardware: TestAudioHardware) -> AudioOutputService {
        AudioOutputService(hal: AudioHALWorker(hardware: hardware, recoveryInterval: nil))
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Audio state did not settle", file: file, line: line)
    }
}

private final class TestAudioHardware: AudioHardwareAccess, @unchecked Sendable {
    struct Device {
        var volume: Float32 = 0.5
        var mute: UInt32 = 0
        var supportsVolume = true
        var supportsMute = true
        var virtualVolume = true
        var settable = true
        var readStatus: OSStatus = noErr
        var writeStatus: OSStatus = noErr
    }

    struct Registration: @unchecked Sendable {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let listener: AudioObjectPropertyListenerBlock
    }

    struct Write {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
    }

    struct State {
        var defaultDevice: AudioObjectID = 10
        var defaultStatus: OSStatus = noErr
        var devices: [AudioObjectID: Device] = [10: .init()]
        var registrations: [Registration] = []
        var addCounts: [AudioObjectPropertySelector: Int] = [:]
        var writes: [Write] = []
        var defaultReads = 0
        var blockNextDefaultRead: DispatchSemaphore?
        var readBlocked = false
        var deferWrites = false
    }

    private let lock = NSLock()
    private var state = State()
    var snapshot: State { lock.withLock { state } }
    func update(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }

    func hasProperty(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard let device = snapshot.devices[object] else { return false }
        switch address.mSelector {
        case 0x766D_7663: return device.supportsVolume && device.virtualVolume
        case kAudioDevicePropertyVolumeScalar: return device.supportsVolume
        case kAudioDevicePropertyMute: return device.supportsMute
        default: return false
        }
    }

    func isSettable(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        hasProperty(object, &address) && snapshot.devices[object]?.settable == true
    }

    func read(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
              _ size: inout UInt32, _ data: UnsafeMutableRawPointer) -> OSStatus {
        if address.mSelector == kAudioHardwarePropertyDefaultOutputDevice {
            let release = lock.withLock {
                state.defaultReads += 1
                let release = state.blockNextDefaultRead
                state.blockNextDefaultRead = nil
                state.readBlocked = release != nil
                return release
            }
            if let release {
                _ = release.wait(timeout: .now() + 5)
                update { $0.readBlocked = false }
            }
            let current = snapshot
            data.storeBytes(of: current.defaultDevice, as: AudioObjectID.self)
            return current.defaultStatus
        }
        guard let device = snapshot.devices[object] else { return kAudioHardwareBadObjectError }
        guard device.readStatus == noErr else { return device.readStatus }
        switch address.mSelector {
        case 0x766D_7663, kAudioDevicePropertyVolumeScalar:
            guard hasProperty(object, &address) else { return kAudioHardwareUnknownPropertyError }
            data.storeBytes(of: device.volume, as: Float32.self)
        case kAudioDevicePropertyMute:
            guard device.supportsMute else { return kAudioHardwareUnknownPropertyError }
            data.storeBytes(of: device.mute, as: UInt32.self)
        case kAudioDevicePropertyTransportType:
            data.storeBytes(of: UInt32(kAudioDeviceTransportTypeBuiltIn), as: UInt32.self)
        default: return kAudioHardwareUnknownPropertyError
        }
        return noErr
    }

    func write(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
               _ size: UInt32, _ data: UnsafeRawPointer) -> OSStatus {
        guard let device = snapshot.devices[object] else { return kAudioHardwareBadObjectError }
        update { $0.writes.append(.init(object: object, selector: address.mSelector)) }
        guard device.writeStatus == noErr else { return device.writeStatus }
        guard isSettable(object, &address) else { return kAudioHardwareIllegalOperationError }
        if snapshot.deferWrites { return noErr }
        if address.mSelector == kAudioDevicePropertyMute {
            update { $0.devices[object]?.mute = data.load(as: UInt32.self) }
        } else {
            update { $0.devices[object]?.volume = data.load(as: Float32.self) }
        }
        return noErr
    }

    func addListener(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
                     _ queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        update {
            $0.addCounts[address.mSelector, default: 0] += 1
            $0.registrations.append(.init(object: object, address: address, queue: queue, listener: listener))
        }
        return noErr
    }

    func removeListener(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
                        _ queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock) {
        update { $0.registrations.removeAll { $0.object == object && $0.address.mSelector == address.mSelector } }
    }

    func emit(_ selector: AudioObjectPropertySelector) {
        for registration in snapshot.registrations where registration.address.mSelector == selector {
            registration.queue.async {
                var address = registration.address
                withUnsafePointer(to: &address) { registration.listener(1, $0) }
            }
        }
    }
}

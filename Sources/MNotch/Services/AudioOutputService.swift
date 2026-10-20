import CoreAudio
import Foundation
import Observation

/// All potentially blocking CoreAudio work lives on this dedicated serial
/// queue. A broken third-party/HDMI/Bluetooth driver can therefore stall audio
/// updates without parking MNotch's main actor.
final class AudioHALWorker: @unchecked Sendable {
    struct Snapshot: Sendable {
        let volume: Double
        let muted: Bool
        let outputName: String
        let outputSymbol: String
        let volumeAvailable: Bool
        let muteAvailable: Bool
        let sampledAt: TimeInterval
    }

    typealias Update = @Sendable (Snapshot) -> Void

    private let queue = DispatchQueue(label: "com.mnotch.audio-hal", qos: .userInitiated)
    private let hardware: any AudioHardwareAccess
    private let recoveryInterval: TimeInterval?
    private var recoveryTimer: DispatchSourceTimer?
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var started = false
    private var generation: UInt64 = 0
    private var update: Update?
    private var volume: Double = 0.5
    private var muted = false
    private var outputName = ""
    private var outputSymbol = "laptopcomputer"
    private var pendingVolume: Double?
    private var pendingMute: Bool?
    private var writeDrainScheduled = false
    private var refreshScheduled = false
    private var deviceRefreshScheduled = false
    private var serviceRestartPending = false
    private var volumeAvailable = false
    private var muteAvailable = false
    private var volumeWriteFailed = false
    private var muteWriteFailed = false
    private var lastFailure: (DiagnosticCode, OSStatus)?

    // 'vmvc' — virtual main volume (same selector AudioHardwareService used).
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: AudioObjectPropertySelector(0x766D_7663),
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var serviceRestartAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyServiceRestarted,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var transportAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var volumeListener: AudioObjectPropertyListenerBlock = { _, _ in }
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock = { _, _ in }

    init(hardware: any AudioHardwareAccess = CoreAudioHardwareAccess(), recoveryInterval: TimeInterval? = 1) {
        self.hardware = hardware
        self.recoveryInterval = recoveryInterval
    }

    func start(update: @escaping Update) {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.generation &+= 1
            let generation = self.generation
            self.update = update

            // CoreAudio invokes these on `queue`. Re-dispatching once is
            // deliberate: never add/remove/query properties from inside HAL's
            // own notification delivery and coalesce bursts naturally.
            self.volumeListener = { [weak self] _, _ in
                guard let self, self.started, self.generation == generation,
                      !self.refreshScheduled else { return }
                self.refreshScheduled = true
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.refreshScheduled = false
                    guard self.started, self.generation == generation else { return }
                    self.followDefaultDevice()
                }
            }
            self.defaultDeviceListener = { [weak self] count, addresses in
                guard let self, self.started, self.generation == generation else { return }
                if UnsafeBufferPointer(start: addresses, count: Int(count)).contains(where: {
                    $0.mSelector == kAudioHardwarePropertyServiceRestarted
                }) {
                    self.serviceRestartPending = true
                }
                guard !self.deviceRefreshScheduled else { return }
                self.deviceRefreshScheduled = true
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.deviceRefreshScheduled = false
                    guard self.started, self.generation == generation else { return }
                    if self.serviceRestartPending {
                        self.serviceRestartPending = false
                        // HAL discards client state on a service reset, even
                        // when the new default device reuses the same ID.
                        self.removeSystemListeners()
                        self.detachDevice()
                        self.addSystemListeners()
                        AppDiagnostics.record(.audio, .serviceRestarted)
                    }
                    self.followDefaultDevice()
                }
            }

            // Register before the first query so a route change cannot fall
            // into a gap between reading the default and installing its listener.
            self.addSystemListeners()
            self.followDefaultDevice()
            if let interval = self.recoveryInterval {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
                timer.setEventHandler { [weak self] in
                    guard let self, self.started, self.generation == generation else { return }
                    // Recover from missed route notifications and expire the
                    // main actor's control lease if a HAL call ever stalls.
                    self.followDefaultDevice()
                }
                self.recoveryTimer = timer
                timer.resume()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            // Invalidate queued callback work before removing registrations.
            self.started = false
            self.generation &+= 1
            self.pendingVolume = nil
            self.pendingMute = nil
            self.writeDrainScheduled = false
            self.refreshScheduled = false
            self.deviceRefreshScheduled = false
            self.serviceRestartPending = false
            self.recoveryTimer?.cancel()
            self.recoveryTimer = nil
            self.removeSystemListeners()
            self.detachDevice()
            self.update = nil
        }
    }

    func refresh() {
        queue.async { [weak self] in self?.followDefaultDevice() }
    }

    /// Rapid key repeats collapse to the latest requested values. Only one
    /// queue drain touches HAL, instead of one blocking round-trip per event.
    func setVolume(_ value: Double) {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.pendingVolume = SafeNumeric.unit(value, fallback: self.volume)
            self.scheduleWriteDrain()
        }
    }

    func setMuted(_ muted: Bool) {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.pendingMute = muted
            self.scheduleWriteDrain()
        }
    }

    private func scheduleWriteDrain() {
        guard !writeDrainScheduled else { return }
        writeDrainScheduled = true
        queue.async { [weak self] in
            self?.drainWrites()
        }
    }

    private func drainWrites() {
        writeDrainScheduled = false
        // Never send a command solely to the ID cached by a past notification.
        // Devices can disappear or change while callbacks are being delivered.
        followDefaultDevice(publishSnapshot: false)
        guard started, deviceID != kAudioObjectUnknown else {
            pendingVolume = nil
            pendingMute = nil
            return
        }

        if let requestedVolume = pendingVolume {
            pendingVolume = nil
            var level = Float32(requestedVolume)
            let size = UInt32(MemoryLayout<Float32>.size)
            let status = hardware.write(deviceID, &volumeAddress, size, &level)
            if status == noErr {
                volume = Double(level)
                volumeWriteFailed = false
                volumeAvailable = true
                if muted, requestedVolume > 0 { pendingMute = false }
            } else {
                volumeWriteFailed = true
                volumeAvailable = false
                recordFailure(.writeFailed, status: status)
            }
        }

        if let requestedMute = pendingMute {
            pendingMute = nil
            var value: UInt32 = requestedMute ? 1 : 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            let status = hardware.write(deviceID, &muteAddress, size, &value)
            if status == noErr {
                muted = requestedMute
                muteWriteFailed = false
                muteAvailable = true
            } else {
                muteWriteFailed = true
                muteAvailable = false
                recordFailure(.writeFailed, status: status)
            }
        }
        // HAL writes may apply asynchronously. Keep the accepted value until
        // a property notification or the next recovery poll confirms it;
        // reading immediately can restore the old level during key repeats.
        publish()

        // A request can arrive while a slow HAL call is returning.
        if pendingVolume != nil || pendingMute != nil {
            scheduleWriteDrain()
        }
    }

    private func followDefaultDevice(publishSnapshot: Bool = true) {
        guard started else { return }
        let old = deviceID
        var newDevice = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = hardware.read(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress, &size, &newDevice
        )
        guard status == noErr, newDevice != kAudioObjectUnknown else {
            if status != noErr { recordFailure(.readFailed, status: status) }
            detachDevice()
            publish()
            return
        }

        guard started else { return }
        if old != newDevice {
            detachDevice()
            lastFailure = nil
            deviceID = newDevice
            selectVolumeProperty()
            addDeviceListeners()
            refreshRoute()
            AppDiagnostics.record(.audio, .routeChanged)
        }
        refreshValues(publishSnapshot: publishSnapshot)
    }

    private func addSystemListeners() {
        let object = AudioObjectID(kAudioObjectSystemObject)
        let defaultStatus = hardware.addListener(object, &defaultDeviceAddress, queue, defaultDeviceListener)
        let restartStatus = hardware.addListener(object, &serviceRestartAddress, queue, defaultDeviceListener)
        if defaultStatus != noErr { recordFailure(.listenerFailed, status: defaultStatus) }
        if restartStatus != noErr { recordFailure(.listenerFailed, status: restartStatus) }
    }

    private func removeSystemListeners() {
        let object = AudioObjectID(kAudioObjectSystemObject)
        hardware.removeListener(object, &defaultDeviceAddress, queue, defaultDeviceListener)
        hardware.removeListener(object, &serviceRestartAddress, queue, defaultDeviceListener)
    }

    private func selectVolumeProperty() {
        // Some outputs expose only the HAL main scalar, without the virtual
        // main selector. Outputs with neither stay under native key control.
        var virtual = volumeAddress
        virtual.mSelector = AudioObjectPropertySelector(0x766D_7663)
        var scalar = virtual
        scalar.mSelector = kAudioDevicePropertyVolumeScalar
        if hardware.hasProperty(deviceID, &virtual), hardware.isSettable(deviceID, &virtual) {
            volumeAddress = virtual
        } else if hardware.hasProperty(deviceID, &scalar) {
            volumeAddress = scalar
        } else {
            volumeAddress = virtual
        }
    }

    private func addDeviceListeners() {
        if hardware.hasProperty(deviceID, &volumeAddress) {
            let status = hardware.addListener(deviceID, &volumeAddress, queue, volumeListener)
            if status != noErr { recordFailure(.listenerFailed, status: status) }
        }
        if hardware.hasProperty(deviceID, &muteAddress) {
            let status = hardware.addListener(deviceID, &muteAddress, queue, volumeListener)
            if status != noErr { recordFailure(.listenerFailed, status: status) }
        }
    }

    private func detachDevice() {
        if deviceID != kAudioObjectUnknown {
            hardware.removeListener(deviceID, &volumeAddress, queue, volumeListener)
            hardware.removeListener(deviceID, &muteAddress, queue, volumeListener)
        }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        volumeAvailable = false
        muteAvailable = false
        volumeWriteFailed = false
        muteWriteFailed = false
        outputName = ""
        outputSymbol = "speaker.wave.2.fill"
    }

    private func refreshRoute() {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = hardware.read(deviceID, &transportAddress, &size, &transport)

        var nameRef: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if hardware.read(
            deviceID, &nameAddress, &size, &nameRef
        ) == noErr, let name = nameRef?.takeRetainedValue() {
            outputName = name as String
        }

        let lowerName = outputName.lowercased()
        outputSymbol = switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            lowerName.contains("airpods pro") || lowerName.contains("airpods max")
                ? "airpods.pro"
                : lowerName.contains("airpods") ? "airpods" : "headphones"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeHDMI:
            "hifispeaker.fill"
        case kAudioDeviceTransportTypeAirPlay:
            "airplayaudio"
        default:
            "speaker.wave.2.fill"
        }
    }

    private func refreshValues(publishSnapshot: Bool = true) {
        guard started, deviceID != kAudioObjectUnknown else { return }
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let volumeStatus = hardware.read(deviceID, &volumeAddress, &size, &level)
        let validVolume = volumeStatus == noErr && size == MemoryLayout<Float32>.size
            && level.isFinite && (0...1).contains(level)
        volumeAvailable = validVolume
            && hardware.isSettable(deviceID, &volumeAddress) && !volumeWriteFailed
        if validVolume {
            volume = Double(level)
        } else if volumeStatus != noErr {
            recordFailure(.readFailed, status: volumeStatus)
        }

        var muteValue: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let muteStatus = hardware.read(deviceID, &muteAddress, &size, &muteValue)
        let validMute = muteStatus == noErr && size == MemoryLayout<UInt32>.size
        muteAvailable = validMute
            && hardware.isSettable(deviceID, &muteAddress) && !muteWriteFailed
        if validMute {
            muted = muteValue != 0
        } else if muteStatus != noErr, hardware.hasProperty(deviceID, &muteAddress) {
            recordFailure(.readFailed, status: muteStatus)
        }
        if publishSnapshot { publish() }
    }

    private func recordFailure(_ code: DiagnosticCode, status: OSStatus) {
        guard lastFailure?.0 != code || lastFailure?.1 != status else { return }
        lastFailure = (code, status)
        AppDiagnostics.record(.audio, code, status: status)
    }

    private func publish() {
        guard started else { return }
        update?(Snapshot(
            volume: volume,
            muted: muted,
            outputName: outputName,
            outputSymbol: outputSymbol,
            volumeAvailable: volumeAvailable,
            muteAvailable: muteAvailable,
            sampledAt: ProcessInfo.processInfo.systemUptime
        ))
    }
}

/// System output volume: read, write, and live-follow external changes via
/// CoreAudio property listeners on the default output device.
@MainActor
@Observable
final class AudioOutputService {
    var isRunning: Bool { started }
    /// A stalled HAL queue must not leave the global key tap swallowing keys.
    /// A fresh snapshot renews this short lease; checking it never touches HAL.
    var isResponsive: Bool {
        guard started, let lastResponse else { return false }
        return now() - lastResponse < 3
    }
    var canSetVolume: Bool { isResponsive && volumeAvailable && (!muted || muteAvailable) }
    var canSetMute: Bool { isResponsive && muteAvailable }
    private(set) var volume: Double = 0.5
    private(set) var muted = false
    private(set) var outputName = ""
    private(set) var outputSymbol = "laptopcomputer"
    private(set) var volumeAvailable = false
    private(set) var muteAvailable = false

    /// Fired on every observed change (external or our own writes).
    @ObservationIgnored var onVolumeChanged: ((Double, Bool) -> Void)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let hal: AudioHALWorker
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private var lastResponse: TimeInterval?
    @ObservationIgnored private var runGeneration: UInt64 = 0

    init(hal: AudioHALWorker = AudioHALWorker(), now: @escaping () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
    }) {
        self.hal = hal
        self.now = now
    }

    func start() {
        guard !started else { return }
        started = true
        runGeneration &+= 1
        let generation = runGeneration
        let mailbox = LatestValueMailbox<AudioHALWorker.Snapshot>()
        hal.start { [weak self] snapshot in
            guard mailbox.submit(snapshot) else { return }
            Task { @MainActor [weak self] in
                let latest = mailbox.take()
                guard let self, self.started, self.runGeneration == generation, let latest else { return }
                self.apply(latest)
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        lastResponse = nil
        volumeAvailable = false
        muteAvailable = false
        runGeneration &+= 1
        hal.stop()
    }

    func refresh() {
        guard started else { return }
        hal.refresh()
    }

    func setVolume(_ newVolume: Double) {
        guard isResponsive else { return }
        guard newVolume.isFinite else { return }
        let clamped = SafeNumeric.unit(newVolume)
        volume = clamped
        if muted, clamped > 0 { muted = false }
        hal.setVolume(clamped)
    }

    func setMuted(_ newMuted: Bool) {
        guard isResponsive else { return }
        muted = newMuted
        hal.setMuted(newMuted)
    }

    private func apply(_ snapshot: AudioHALWorker.Snapshot) {
        let changed = volume != snapshot.volume || muted != snapshot.muted
        volume = SafeNumeric.unit(snapshot.volume, fallback: volume)
        muted = snapshot.muted
        outputName = snapshot.outputName
        outputSymbol = snapshot.outputSymbol
        volumeAvailable = snapshot.volumeAvailable
        muteAvailable = snapshot.muteAvailable
        lastResponse = snapshot.sampledAt
        if changed {
            onVolumeChanged?(volume, muted)
        }
    }
}

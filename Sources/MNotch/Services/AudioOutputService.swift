import CoreAudio
import Foundation
import Observation

/// All potentially blocking CoreAudio work lives on this dedicated serial
/// queue. A broken third-party/HDMI/Bluetooth driver can therefore stall audio
/// updates without parking MNotch's main actor.
private final class AudioHALWorker: @unchecked Sendable {
    struct Snapshot: Sendable {
        let volume: Double
        let muted: Bool
        let outputName: String
        let outputSymbol: String
    }

    typealias Update = @Sendable (Snapshot) -> Void

    private let queue = DispatchQueue(label: "com.mnotch.audio-hal", qos: .userInitiated)
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
                self?.queue.async { [weak self] in
                    guard let self, self.started, self.generation == generation else { return }
                    self.refresh()
                }
            }
            self.defaultDeviceListener = { [weak self] _, _ in
                self?.queue.async { [weak self] in
                    guard let self, self.started, self.generation == generation else { return }
                    self.followDefaultDevice()
                }
            }

            self.followDefaultDevice()
            guard self.started, self.generation == generation else { return }
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &self.defaultDeviceAddress,
                self.queue,
                self.defaultDeviceListener
            )
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
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &self.defaultDeviceAddress,
                self.queue,
                self.defaultDeviceListener
            )
            if self.deviceID != kAudioObjectUnknown {
                AudioObjectRemovePropertyListenerBlock(
                    self.deviceID, &self.volumeAddress, self.queue, self.volumeListener
                )
                AudioObjectRemovePropertyListenerBlock(
                    self.deviceID, &self.muteAddress, self.queue, self.volumeListener
                )
            }
            self.deviceID = AudioObjectID(kAudioObjectUnknown)
            self.update = nil
        }
    }

    /// Rapid key repeats collapse to the latest requested values. Only one
    /// queue drain touches HAL, instead of one blocking round-trip per event.
    func setVolume(_ value: Double) {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.pendingVolume = min(max(value, 0), 1)
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
        guard started, deviceID != kAudioObjectUnknown else {
            pendingVolume = nil
            pendingMute = nil
            return
        }

        if let requestedVolume = pendingVolume {
            pendingVolume = nil
            var level = Float32(requestedVolume)
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(
                deviceID, &volumeAddress, 0, nil, size, &level
            ) == noErr {
                volume = Double(level)
            }
            if muted, requestedVolume > 0 {
                pendingMute = false
            }
        }

        if let requestedMute = pendingMute {
            pendingMute = nil
            var value: UInt32 = requestedMute ? 1 : 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectSetPropertyData(
                deviceID, &muteAddress, 0, nil, size, &value
            ) == noErr {
                muted = requestedMute
            }
        }
        publish()

        // A request can arrive while a slow HAL call is returning.
        if pendingVolume != nil || pendingMute != nil {
            scheduleWriteDrain()
        }
    }

    private func followDefaultDevice() {
        guard started else { return }
        let old = deviceID
        var newDevice = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress, 0, nil, &size, &newDevice
        ) == noErr, newDevice != kAudioObjectUnknown else { return }

        if old != kAudioObjectUnknown, old != newDevice {
            AudioObjectRemovePropertyListenerBlock(
                old, &volumeAddress, queue, volumeListener
            )
            AudioObjectRemovePropertyListenerBlock(
                old, &muteAddress, queue, volumeListener
            )
        }
        guard started else { return }
        if old != newDevice {
            deviceID = newDevice
            AudioObjectAddPropertyListenerBlock(
                newDevice, &volumeAddress, queue, volumeListener
            )
            AudioObjectAddPropertyListenerBlock(
                newDevice, &muteAddress, queue, volumeListener
            )
            refreshRoute()
        }
        refresh()
    }

    private func refreshRoute() {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(
            deviceID, &transportAddress, 0, nil, &size, &transport
        )

        var nameRef: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(
            deviceID, &nameAddress, 0, nil, &size, &nameRef
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

    private func refresh() {
        guard started, deviceID != kAudioObjectUnknown else { return }
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(
            deviceID, &volumeAddress, 0, nil, &size, &level
        ) == noErr {
            volume = Double(level)
        }

        var muteValue: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(
            deviceID, &muteAddress, 0, nil, &size, &muteValue
        ) == noErr {
            muted = muteValue != 0
        }
        publish()
    }

    private func publish() {
        guard started else { return }
        update?(Snapshot(
            volume: volume,
            muted: muted,
            outputName: outputName,
            outputSymbol: outputSymbol
        ))
    }
}

/// System output volume: read, write, and live-follow external changes via
/// CoreAudio property listeners on the default output device.
@MainActor
@Observable
final class AudioOutputService {
    private(set) var volume: Double = 0.5
    private(set) var muted = false
    private(set) var outputName = ""
    private(set) var outputSymbol = "laptopcomputer"

    /// Fired on every observed change (external or our own writes).
    @ObservationIgnored var onVolumeChanged: ((Double, Bool) -> Void)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let hal = AudioHALWorker()

    func start() {
        guard !started else { return }
        started = true
        hal.start { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.apply(snapshot)
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        hal.stop()
    }

    func refresh() {
        // HAL notifications keep this snapshot current. This method remains a
        // harmless compatibility hook for callers that request a refresh.
    }

    func setVolume(_ newVolume: Double) {
        guard started else { return }
        let clamped = min(max(newVolume, 0), 1)
        volume = clamped
        if muted, clamped > 0 { muted = false }
        hal.setVolume(clamped)
    }

    func setMuted(_ newMuted: Bool) {
        guard started else { return }
        muted = newMuted
        hal.setMuted(newMuted)
    }

    private func apply(_ snapshot: AudioHALWorker.Snapshot) {
        let changed = volume != snapshot.volume || muted != snapshot.muted
        volume = snapshot.volume
        muted = snapshot.muted
        outputName = snapshot.outputName
        outputSymbol = snapshot.outputSymbol
        if changed {
            onVolumeChanged?(volume, muted)
        }
    }
}

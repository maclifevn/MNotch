import CoreAudio
import Foundation
import Observation

/// System output volume: read, write, and live-follow external changes via
/// CoreAudio property listeners on the default output device.
@MainActor
@Observable
final class AudioOutputService {
    private(set) var volume: Double = 0.5
    private(set) var muted = false

    /// Fired on every observed change (external or our own writes).
    @ObservationIgnored
    var onVolumeChanged: ((Double, Bool) -> Void)?

    private var deviceID = AudioObjectID(kAudioObjectUnknown)

    // 'vmvc' — virtual main volume (same selector AudioHardwareService used).
    private static let volumeSelector = AudioObjectPropertySelector(0x766D_7663)

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: volumeSelector,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        volumeListener = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        followDefaultDevice()
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.defaultDeviceAddress,
            .main
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.followDefaultDevice() }
        }
    }

    private func followDefaultDevice() {
        let old = deviceID
        var newDevice = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.defaultDeviceAddress, 0, nil, &size, &newDevice
        )
        guard newDevice != kAudioObjectUnknown else { return }

        if old != kAudioObjectUnknown, old != newDevice {
            AudioObjectRemovePropertyListenerBlock(old, &Self.volumeAddress, .main, volumeListener)
            AudioObjectRemovePropertyListenerBlock(old, &Self.muteAddress, .main, volumeListener)
        }
        if old != newDevice {
            deviceID = newDevice
            AudioObjectAddPropertyListenerBlock(newDevice, &Self.volumeAddress, .main, volumeListener)
            AudioObjectAddPropertyListenerBlock(newDevice, &Self.muteAddress, .main, volumeListener)
        }
        refresh()
    }

    /// Kept as a stored reference so add/remove use the identical block.
    @ObservationIgnored
    private var volumeListener: AudioObjectPropertyListenerBlock = { _, _ in }

    func refresh() {
        guard deviceID != kAudioObjectUnknown else { return }

        let oldVolume = volume
        let oldMuted = muted

        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(deviceID, &Self.volumeAddress, 0, nil, &size, &level) == noErr {
            volume = Double(level)
        }

        var muteValue: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &Self.muteAddress, 0, nil, &size, &muteValue) == noErr {
            muted = muteValue != 0
        }

        if oldVolume != volume || oldMuted != muted {
            onVolumeChanged?(volume, muted)
        }
    }

    func setVolume(_ newVolume: Double) {
        guard deviceID != kAudioObjectUnknown else { return }
        var level = Float32(min(max(newVolume, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectSetPropertyData(deviceID, &Self.volumeAddress, 0, nil, size, &level) == noErr {
            volume = Double(level)
        }
        if muted, newVolume > 0 {
            setMuted(false)
        }
    }

    func setMuted(_ newMuted: Bool) {
        guard deviceID != kAudioObjectUnknown else { return }
        var value: UInt32 = newMuted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectSetPropertyData(deviceID, &Self.muteAddress, 0, nil, size, &value) == noErr {
            muted = newMuted
        }
    }
}

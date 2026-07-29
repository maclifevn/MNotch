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
    @ObservationIgnored private var started = false

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
    private static var transportAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private(set) var outputName = ""
    /// SF Symbol for the current output route (Alcove shows this bottom-right).
    private(set) var outputSymbol = "laptopcomputer"

    func start() {
        guard !started else { return }
        started = true
        // Never call back into the HAL synchronously from inside one of its own
        // property-listener callbacks: add/remove listener re-enters locks the
        // HAL holds while dispatching, which can deadlock the main thread (the
        // device-change path below rewires listeners). Hopping to the next
        // main-actor turn lets the HAL finish dispatching first; the extra
        // runloop turn is imperceptible for a HUD.
        volumeListener = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        defaultDeviceListener = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.followDefaultDevice() }
        }
        followDefaultDevice()
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.defaultDeviceAddress,
            .main,
            defaultDeviceListener
        )
    }

    func stop() {
        guard started else { return }
        started = false
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.defaultDeviceAddress,
            .main,
            defaultDeviceListener
        )
        if deviceID != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(
                deviceID, &Self.volumeAddress, .main, volumeListener
            )
            AudioObjectRemovePropertyListenerBlock(
                deviceID, &Self.muteAddress, .main, volumeListener
            )
        }
        deviceID = AudioObjectID(kAudioObjectUnknown)
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
            refreshRoute()
        }
        refresh()
    }

    private func refreshRoute() {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &Self.transportAddress, 0, nil, &size, &transport)

        var nameRef: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(deviceID, &Self.nameAddress, 0, nil, &size, &nameRef) == noErr,
           let name = nameRef?.takeRetainedValue() {
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

    /// Kept as a stored reference so add/remove use the identical block.
    @ObservationIgnored
    private var volumeListener: AudioObjectPropertyListenerBlock = { _, _ in }
    @ObservationIgnored
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock = { _, _ in }

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

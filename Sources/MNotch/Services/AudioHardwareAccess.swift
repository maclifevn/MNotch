import CoreAudio
import Foundation

/// Keeps the HAL boundary replaceable so failures and service resets can be
/// tested without changing the Mac's actual output device or volume.
protocol AudioHardwareAccess: Sendable {
    func hasProperty(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool
    func isSettable(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool
    func read(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
              _ size: inout UInt32, _ data: UnsafeMutableRawPointer) -> OSStatus
    func write(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
               _ size: UInt32, _ data: UnsafeRawPointer) -> OSStatus
    func addListener(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
                     _ queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    func removeListener(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
                        _ queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock)
}

struct CoreAudioHardwareAccess: AudioHardwareAccess {
    func hasProperty(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        AudioObjectHasProperty(object, &address)
    }

    func isSettable(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    func read(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
              _ size: inout UInt32, _ data: UnsafeMutableRawPointer) -> OSStatus {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, data)
    }

    func write(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
               _ size: UInt32, _ data: UnsafeRawPointer) -> OSStatus {
        AudioObjectSetPropertyData(object, &address, 0, nil, size, data)
    }

    func addListener(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
                     _ queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        AudioObjectAddPropertyListenerBlock(object, &address, queue, listener)
    }

    func removeListener(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress,
                        _ queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock) {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
    }
}

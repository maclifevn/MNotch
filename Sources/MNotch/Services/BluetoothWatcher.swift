import AppKit
import IOBluetooth
import IOKit

/// Pops a notification when a Bluetooth device connects, with battery level
/// scraped from the IORegistry when the device reports one (AirPods, Magic
/// peripherals). Registry keys are private-ish — everything degrades to nil.
@MainActor
final class BluetoothWatcher: NSObject {
    var onConnect: ((_ name: String, _ symbol: String, _ battery: Int?) -> Void)?

    func start() {
        IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
    }

    @objc private func deviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let name = device.name ?? "Bluetooth Device"
        let symbol = Self.symbol(forName: name, classOfDevice: device.classOfDevice)
        let address = device.addressString

        Task { [weak self] in
            // Registry entries appear shortly after connect.
            try? await Task.sleep(for: .seconds(1))
            let battery = await Task.detached {
                Self.hidBatteryPercent(address: address, name: name)
            }.value
            self?.onConnect?(name, symbol, battery)
        }
    }

    private static func symbol(forName name: String, classOfDevice: BluetoothClassOfDevice) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods pro") || lower.contains("airpods max") { return "airpods.pro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("keyboard") { return "keyboard.fill" }
        if lower.contains("mouse") { return "magicmouse.fill" }
        if lower.contains("trackpad") { return "rectangle.fill" }

        let majorClass = (classOfDevice >> 8) & 0x1F
        switch majorClass {
        case 4: return "headphones" // audio/video
        case 5: return "keyboard.fill" // peripheral
        default: return "wave.3.right.circle.fill"
        }
    }

    /// Battery % from AppleDeviceManagementHIDEventService registry entries,
    /// matched by Bluetooth address (or product name as fallback).
    private nonisolated static func hidBatteryPercent(address: String?, name: String) -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let normalizedAddress = address?
            .replacingOccurrences(of: ":", with: "-")
            .lowercased()

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }

            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(
                    entry, key as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue()
            }

            let entryAddress = (property("DeviceAddress") as? String)?
                .replacingOccurrences(of: ":", with: "-")
                .lowercased()
            let product = property("Product") as? String

            let addressMatch = normalizedAddress != nil && entryAddress == normalizedAddress
            let nameMatch = product == name
            guard addressMatch || nameMatch else { continue }

            // Prefer the averaged left/right level for AirPods.
            let left = property("BatteryPercentLeft") as? Int
            let right = property("BatteryPercentRight") as? Int
            if let left, let right, left > 0 || right > 0 {
                return min(left > 0 ? left : right, right > 0 ? right : left)
            }
            if let percent = property("BatteryPercent") as? Int {
                return percent
            }
        }
        return nil
    }
}

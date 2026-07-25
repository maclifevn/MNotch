import AppKit
import IOBluetooth
import IOKit

/// IOBluetooth's notification token is an Objective-C handle with no Swift
/// Sendable annotation. Registration/unregistration are thread-safe; the box
/// makes the explicit ownership transfer to MainActor visible to Swift 6.
private final class BluetoothNotificationBox: @unchecked Sendable {
    let value: IOBluetoothUserNotification
    init(_ value: IOBluetoothUserNotification) { self.value = value }
}

/// Pops a notification when a Bluetooth device connects, with battery level
/// scraped from the IORegistry when the device reports one (AirPods, Magic
/// peripherals). Registry keys are private-ish — everything degrades to nil.
@MainActor
final class BluetoothWatcher: NSObject {
    var onConnect: ((_ name: String, _ symbol: String, _ battery: Int?) -> Void)?
    var onLowBattery: ((_ name: String, _ symbol: String, _ battery: Int) -> Void)?

    private struct Connected {
        let name: String
        let symbol: String
        let address: String?
    }

    private var connected: [String: Connected] = [:]

    /// For the lock screen connectivity widget.
    var connectedDeviceSummaries: [(name: String, symbol: String)] {
        connected.values.map { ($0.name, $0.symbol) }.sorted { $0.name < $1.name }
    }
    private var warnedLow: Set<String> = []
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: BluetoothNotificationBox] = [:]
    private var batteryTimer: Timer?
    private var runGeneration: UInt64 = 0

    func start() {
        guard batteryTimer == nil else { return }
        runGeneration &+= 1
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )

        // Periodic re-check of connected devices' battery (Settings →
        // Connectivity → Warn on low battery).
        let timer = Timer(timeInterval: 300, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.recheckBatteries() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    func stop() {
        runGeneration &+= 1
        batteryTimer?.invalidate()
        batteryTimer = nil
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.value.unregister() }
        disconnectNotifications.removeAll()
        connected.removeAll()
        warnedLow.removeAll()
        recentPops.removeAll()
    }

    private func recheckBatteries() {
        let settings = SettingsStore.shared
        guard settings.connectivityEnabled, settings.connectivityWarnLow else { return }
        let threshold = Int(settings.connectivityLowThreshold)

        for (key, device) in connected where !warnedLow.contains(key) {
            let generation = runGeneration
            Task { [weak self] in
                let battery = await Task.detached {
                    Self.hidBatteryPercent(address: device.address, name: device.name)
                }.value
                guard let battery, battery > 0, battery <= threshold else { return }
                guard let self,
                      self.runGeneration == generation,
                      self.batteryTimer != nil,
                      !self.warnedLow.contains(key)
                else { return }
                self.warnedLow.insert(key)
                self.onLowBattery?(device.name, device.symbol, battery)
                if SettingsStore.shared.connectivitySoundOnLow {
                    SoundPlayer.play(.deviceLow)
                }
            }
        }
    }

    /// IOBluetooth delivers this on a CoreBluetooth background thread, so the
    /// handler must be nonisolated; plain value reads on the device object are
    /// done here, then everything hops to the main actor.
    /// Addresses recently popped, to swallow reconnect loops.
    private var recentPops: [String: Date] = [:]

    @objc nonisolated private func deviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        // Background Continuity handshakes (iPhone/Watch nearby) and service
        // probes fire this too — nameless connections are never something the
        // user just did, so stay silent for them.
        guard let name = device.name, !name.isEmpty else { return }

        // Only audio devices (4) and peripherals (5) warrant a pop; phones,
        // watches and misc devices connect on their own all the time.
        let majorClass = (device.classOfDevice >> 8) & 0x1F
        guard majorClass == 4 || majorClass == 5 else { return }

        let symbol = Self.symbol(forName: name, classOfDevice: device.classOfDevice)
        let address = device.addressString
        let disconnectNotification = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDisconnected(_:device:))
        ).map(BluetoothNotificationBox.init)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let generation = self.runGeneration
            guard self.batteryTimer != nil else {
                disconnectNotification?.value.unregister()
                return
            }
            let key = address ?? name
            self.connected[key] = Connected(
                name: name, symbol: symbol, address: address
            )
            if let disconnectNotification {
                self.disconnectNotifications[key]?.value.unregister()
                self.disconnectNotifications[key] = disconnectNotification
            }

            // One pop per device per 2 minutes, however often it reconnects.
            if let last = self.recentPops[key], Date().timeIntervalSince(last) < 120 {
                return
            }
            self.recentPops[key] = Date()

            // Registry entries appear shortly after connect.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                  self.runGeneration == generation,
                  self.batteryTimer != nil
            else { return }
            let battery = await Task.detached {
                Self.hidBatteryPercent(address: address, name: name)
            }.value
            guard self.runGeneration == generation,
                  self.batteryTimer != nil
            else { return }
            self.onConnect?(name, symbol, battery)
        }
    }

    @objc nonisolated private func deviceDisconnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        // Each connect registered one disconnect notification; retire it now
        // or registrations accumulate unboundedly across reconnects.
        notification.unregister()
        let key = device.addressString ?? device.name ?? ""
        Task { @MainActor [weak self] in
            self?.connected.removeValue(forKey: key)
            self?.warnedLow.remove(key)
            self?.disconnectNotifications.removeValue(forKey: key)
        }
    }

    private nonisolated static func symbol(forName name: String, classOfDevice: BluetoothClassOfDevice) -> String {
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

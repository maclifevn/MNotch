import Foundation
import IOKit.ps
import Observation

enum PowerEvent: Equatable {
    case pluggedIn(percentage: Int)
    case unplugged(percentage: Int)
    case lowBattery(percentage: Int)
    case lowPowerMode(on: Bool)
}

/// Watches power source changes via IOKit run-loop notifications.
@MainActor
@Observable
final class PowerSourceService {
    private(set) var percentage = 100
    private(set) var isCharging = false
    private(set) var onAC = false

    @ObservationIgnored
    var onPowerEvent: ((PowerEvent) -> Void)?

    @ObservationIgnored private var lastOnAC: Bool?
    @ObservationIgnored private var firedLowWarning = false
    @ObservationIgnored private var powerStateObserver: NSObjectProtocol?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?

    func start() {
        guard runLoopSource == nil else { return }
        readSources(fireEvents: false)

        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let on = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { @MainActor in
                self?.onPowerEvent?(.lowPowerMode(on: on))
            }
        }
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let service = Unmanaged<PowerSourceService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                service.readSources(fireEvents: true)
            }
        }
        let source = IOPSNotificationCreateRunLoopSource(
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        )?.takeRetainedValue()
        guard let source else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    func stop() {
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
        powerStateObserver = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        runLoopSource = nil
    }

    private func readSources(fireEvents: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            if let capacity = desc[kIOPSCurrentCapacityKey] as? Int {
                percentage = min(max(capacity, 0), 100)
            }
            isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                onAC = state == kIOPSACPowerValue
            }
        }

        defer { lastOnAC = onAC }
        guard fireEvents else { return }

        if let last = lastOnAC, last != onAC {
            onPowerEvent?(onAC
                ? .pluggedIn(percentage: percentage)
                : .unplugged(percentage: percentage))
            if onAC {
                firedLowWarning = false
            }
        }

        if !onAC {
            let threshold = Int(SettingsStore.shared.batteryLowThreshold)
            if percentage <= threshold, !firedLowWarning {
                firedLowWarning = true
                onPowerEvent?(.lowBattery(percentage: percentage))
            } else if percentage > threshold {
                firedLowWarning = false
            }
        }
    }
}

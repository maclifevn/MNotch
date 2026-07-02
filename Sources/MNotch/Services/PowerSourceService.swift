import Foundation
import IOKit.ps
import Observation

enum PowerEvent: Equatable {
    case pluggedIn(percentage: Int)
    case unplugged(percentage: Int)
    case lowBattery(percentage: Int)
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
    @ObservationIgnored private var firedLowThresholds: Set<Int> = []

    private static let lowThresholds = [20, 10]

    func start() {
        readSources(fireEvents: false)
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
        ).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
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
                percentage = capacity
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
                firedLowThresholds.removeAll()
            }
        }

        if !onAC {
            for threshold in Self.lowThresholds
            where percentage <= threshold && !firedLowThresholds.contains(threshold) {
                firedLowThresholds.insert(threshold)
                onPowerEvent?(.lowBattery(percentage: percentage))
                break
            }
        }
    }
}

import Foundation
import CoreFoundation

enum SafeNumeric {
    static func number(_ raw: Any?) -> Double? {
        let result: Double?
        switch raw {
        case let n as NSNumber:
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            result = n.doubleValue
        case let s as String: result = Double(s)
        default: result = nil
        }
        guard let result, result.isFinite else { return nil }
        return result
    }

    /// Double(Int.max) rounds UP on 64-bit systems, so an inclusive comparison
    /// with that value still traps. Use the standard library's checked conversion.
    static func integer(_ number: Double?) -> Int? {
        guard let number, number.isFinite else { return nil }
        return Int(exactly: number.rounded(.towardZero))
    }

    static func unit(_ value: Double, fallback: Double = 0) -> Double {
        value.isFinite ? min(max(value, 0), 1) : fallback
    }

    static func date(seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite,
              (-62_135_596_800...253_402_300_799).contains(seconds)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

enum PreferenceNumberPolicy {
    struct Rule {
        let range: ClosedRange<Double>
        let fallback: Double
    }

    // These are the ranges already offered by Settings. A damaged preference
    // must not reach Int conversions, Task.sleep, timers or NSWindow geometry.
    static let rules: [String: Rule] = [
        "tuning.width": Rule(range: -20...40, fallback: 0),
        "tuning.height": Rule(range: -8...24, fallback: 0),
        "battery.duration": Rule(range: 1...10, fallback: 5),
        "battery.threshold": Rule(range: 5...50, fallback: 10),
        "bt.duration": Rule(range: 1...10, fallback: 5),
        "bt.threshold": Rule(range: 10...50, fallback: 20),
        "focus.duration": Rule(range: 1...10, fallback: 5),
        "pomo.work": Rule(range: 10...60, fallback: 25),
        "pomo.shortBreak": Rule(range: 3...15, fallback: 5),
        "pomo.longBreak": Rule(range: 10...30, fallback: 15),
        "pomo.cycles": Rule(range: 2...6, fallback: 4),
        "display.duration": Rule(range: 0.5...10, fallback: 1.5),
        "sound.duration": Rule(range: 0.5...10, fallback: 1.5),
        "media.idleDuration": Rule(range: 1...10, fallback: 3),
        "cal.timeBefore": Rule(range: 5...60, fallback: 15),
        "cal.peekDuration": Rule(range: 2...10, fallback: 4),
        "lock.keepAwake": Rule(range: 0...60, fallback: 0),
        "lock.idle": Rule(range: 1...30, fallback: 10),
        "lock.offset": Rule(range: -200...200, fallback: 0),
        "agent.duration": Rule(range: 2...10, fallback: 4),
    ]

    static func value(_ raw: Any?, key: String, fallback: Double) -> Double {
        guard let number = SafeNumeric.number(raw),
              rules[key]?.range.contains(number) ?? true else {
            return rules[key]?.fallback ?? fallback
        }
        return number
    }
}

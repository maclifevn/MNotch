enum IdleActivity: String, CaseIterable, Sendable {
    case none, playing, calendar, duo
}

enum LockCardStyle: String, CaseIterable {
    case glass, clear, frosted
}

enum HUDBarStyle: String, CaseIterable {
    case white, accent, decibel
}

enum AnimSpeed: String, CaseIterable {
    case smooth, fast, instant
}

enum WaveformStyle: String, CaseIterable {
    case monochrome, colored, gradient
}

enum MediaQuickAction: String, CaseIterable {
    case favorite, shuffle, repeatMode, copy
}

enum MediaBadgeStyle: String, CaseIterable {
    case none, appIcon
}

enum SoundIconStyle: String, CaseIterable {
    case symbol, device
}

enum VolumeStep: String, CaseIterable, Sendable {
    case onePercent = "1"
    case twoPercent = "2"
    case fivePercent = "5"
    case tenPercent = "10"

    var increment: Double {
        switch self {
        case .onePercent: 0.01
        case .twoPercent: 0.02
        case .fivePercent: 0.05
        case .tenPercent: 0.10
        }
    }
}

enum CalendarUse: String, CaseIterable {
    case both, notifications, activity
}

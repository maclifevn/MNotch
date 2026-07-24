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

enum CalendarUse: String, CaseIterable {
    case both, notifications, activity
}

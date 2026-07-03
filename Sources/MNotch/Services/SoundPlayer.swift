import AppKit

/// System-sound playback for pops and settings previews.
@MainActor
enum SoundPlayer {
    enum Effect: String {
        case lowBattery = "Funk"
        case deviceLow = "Sosumi"
        case event = "Glass"
        case chime = "Ping"
        case sleep = "Submarine"
        case lock = "Bottle"
        case unlock = "Pop"
    }

    static func play(_ effect: Effect) {
        NSSound(named: effect.rawValue)?.play()
    }
}

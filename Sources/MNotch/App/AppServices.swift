import Foundation

/// Single owner of all long-lived services; shared across notch panels.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let media = MediaRemoteService()
    let audio = AudioOutputService()

    private init() {}

    func startAll() {
        media.start()
        audio.start()
    }
}

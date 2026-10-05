import Foundation

/// The same install boundary used by MFinder, limited to MNotch's file work.
/// Stop accepting new work, let existing copies/drags finish, then relaunch.
@MainActor
final class UpdateInstallationCoordinator {
    struct Dependencies {
        var pause: () -> Void
        var resume: () -> Void
        var hasActiveWork: () -> Bool
    }

    enum State: Equatable { case active, waiting, prepared }
    private let dependencies: Dependencies
    private var generation: UInt64 = 0
    private(set) var state: State = .active

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    static func live() -> UpdateInstallationCoordinator {
        .init(dependencies: .init(
            pause: { ShelfStore.shared.beginUpdatePreparation() },
            resume: { ShelfStore.shared.cancelUpdatePreparation() },
            hasActiveWork: { ShelfStore.shared.isBusy || ShelfOutgoingDragState.hasLiveSession }
        ))
    }

    var hasActiveWork: Bool { dependencies.hasActiveWork() }

    func prepare() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard state == .active else { return state == .prepared }
        generation &+= 1
        let token = generation
        state = .waiting
        dependencies.pause()
        defer { if generation == token, state == .waiting { cancel() } }
        while dependencies.hasActiveWork() {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch {
                if generation == token { cancel() }
                return false
            }
            guard !Task.isCancelled, generation == token, state == .waiting else { return false }
        }
        guard !Task.isCancelled, generation == token, state == .waiting else { return false }
        state = .prepared
        return true
    }

    func cancel() {
        generation &+= 1
        guard state != .active else { return }
        state = .active
        dependencies.resume()
    }
}

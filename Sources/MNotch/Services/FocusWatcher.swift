import AppKit

private struct FocusModeInfo: Sendable {
    let name: String
    let symbol: String
}

private struct FocusReadResult: Sendable {
    let available: Bool
    let identifier: String?
    let modeNames: [String: FocusModeInfo]
}

/// Keeps protected-file IO and JSON decoding away from the animation thread.
private actor FocusDatabaseReader {
    private var cachedModeNames: [String: FocusModeInfo] = [:]

    func read(directory: URL) -> FocusReadResult {
        guard let assertions = try? Data(
            contentsOf: directory.appending(path: "Assertions.json")
        ) else {
            return FocusReadResult(available: false, identifier: nil, modeNames: cachedModeNames)
        }

        if cachedModeNames.isEmpty {
            cachedModeNames = loadModeNames(from: directory)
        }

        return FocusReadResult(
            available: true,
            identifier: activeModeIdentifier(in: assertions),
            modeNames: cachedModeNames
        )
    }

    private func loadModeNames(from directory: URL) -> [String: FocusModeInfo] {
        guard let data = try? Data(
            contentsOf: directory.appending(path: "ModeConfigurations.json")
        ),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let dataArray = root["data"] as? [[String: Any]]
        else { return [:] }

        var result: [String: FocusModeInfo] = [:]
        for entry in dataArray {
            guard let configs = entry["modeConfigurations"] as? [String: Any] else { continue }
            for (identifier, value) in configs {
                guard let config = value as? [String: Any],
                      let mode = config["mode"] as? [String: Any]
                else { continue }
                result[identifier] = FocusModeInfo(
                    name: mode["name"] as? String ?? focusFallbackName(for: identifier),
                    symbol: mode["symbolImageName"] as? String ?? "moon.fill"
                )
            }
        }
        return result
    }

    private func activeModeIdentifier(in assertionsData: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: assertionsData) as? [String: Any],
              let dataArray = root["data"] as? [[String: Any]]
        else { return nil }
        for entry in dataArray {
            guard let records = entry["storeAssertionRecords"] as? [[String: Any]] else { continue }
            for record in records {
                if let details = record["assertionDetails"] as? [String: Any],
                   let identifier = details["assertionDetailsModeIdentifier"] as? String {
                    return identifier
                }
            }
        }
        return nil
    }
}

private func focusFallbackName(for identifier: String) -> String {
    if identifier.contains("default") { return L10n.string("Do Not Disturb") }
    if identifier.contains("sleep") { return L10n.string("Sleep") }
    return identifier.components(separatedBy: ".").last?.capitalized
        ?? L10n.string("Focus")
}

/// Focus (Do Not Disturb) state from ~/Library/DoNotDisturb/DB — the same
/// files Control Center writes. Reading them requires Full Disk Access;
/// without it `available` stays false and the Settings pane explains how to
/// grant it. Polls every 4s while an enabled surface needs Focus state.
@MainActor
@Observable
final class FocusWatcher {
    struct Mode: Equatable, Sendable {
        let identifier: String
        let name: String
        let symbol: String
    }

    private(set) var available = false
    private(set) var current: Mode?
    var isFocused: Bool { current != nil }

    @ObservationIgnored var onChange: ((Mode?, Mode?) -> Void)?

    @ObservationIgnored private let reader = FocusDatabaseReader()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loggedUnavailable = false
    /// The first readable poll after a start adopts the current mode silently —
    /// so launching the app, or resuming from display sleep, never replays an
    /// already-active Focus as a fresh "Focus on" pop + sound.
    @ObservationIgnored private var establishingBaseline = false

    private static var dbDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/DoNotDisturb/DB")
    }

    func start() {
        guard timer == nil else { return }
        establishingBaseline = true
        let timer = Timer(timeInterval: 4, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.requestPoll() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        requestPoll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pollTask?.cancel()
        pollTask = nil
        current = nil
        available = false
    }

    private func requestPoll() {
        guard pollTask == nil else { return }
        let directory = Self.dbDirectory
        pollTask = Task { [weak self, reader] in
            let result = await reader.read(directory: directory)
            guard !Task.isCancelled, let self else { return }
            self.pollTask = nil
            self.apply(result)
        }
    }

    private func apply(_ result: FocusReadResult) {
        available = result.available
        guard result.available else {
            // An unreadable DB must not leave stale Focus filtering active.
            current = nil
            if !loggedUnavailable {
                loggedUnavailable = true
                mnotchLog.notice("focus: DoNotDisturb DB unreadable (needs Full Disk Access)")
            }
            return
        }

        loggedUnavailable = false
        let newMode = result.identifier.map { identifier in
            let info = result.modeNames[identifier]
            return Mode(
                identifier: identifier,
                name: info?.name ?? focusFallbackName(for: identifier),
                symbol: info?.symbol ?? "moon.fill"
            )
        }

        // Silently adopt the state present when the watcher (re)started; only
        // transitions that happen while it's running should surface a pop.
        if establishingBaseline {
            establishingBaseline = false
            current = newMode
            return
        }

        if newMode != current {
            let old = current
            current = newMode
            onChange?(old, newMode)
        }
    }
}

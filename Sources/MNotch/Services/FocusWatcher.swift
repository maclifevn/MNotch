import AppKit

/// Focus (Do Not Disturb) state from ~/Library/DoNotDisturb/DB — the same
/// files Control Center writes. Reading them requires Full Disk Access;
/// without it `available` stays false and the Settings pane explains how to
/// grant it. Polls every 4s (two tiny JSON files) while enabled.
@MainActor
@Observable
final class FocusWatcher {
    struct Mode: Equatable {
        let identifier: String
        let name: String
        let symbol: String
    }

    private(set) var available = false
    private(set) var current: Mode?
    var isFocused: Bool { current != nil }

    @ObservationIgnored var onChange: ((Mode?, Mode?) -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var modeNames: [String: (name: String, symbol: String)] = [:]
    @ObservationIgnored private var loggedUnavailable = false

    private static var dbDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/DoNotDisturb/DB")
    }

    func start() {
        let timer = Timer(timeInterval: 4, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func poll() {
        guard SettingsStore.shared.focusEnabled else { return }

        guard let assertions = try? Data(
            contentsOf: Self.dbDirectory.appending(path: "Assertions.json")
        ) else {
            available = false
            if !loggedUnavailable {
                loggedUnavailable = true
                mnotchLog.notice("focus: DoNotDisturb DB unreadable (needs Full Disk Access)")
            }
            return
        }
        available = true
        loadModeNames()

        let identifier = Self.activeModeIdentifier(in: assertions)
        let newMode = identifier.map { id in
            let info = modeNames[id]
            return Mode(
                identifier: id,
                name: info?.name ?? Self.fallbackName(for: id),
                symbol: info?.symbol ?? "moon.fill"
            )
        }

        if newMode != current {
            let old = current
            current = newMode
            onChange?(old, newMode)
        }
    }

    private func loadModeNames() {
        guard modeNames.isEmpty,
              let data = try? Data(
                contentsOf: Self.dbDirectory.appending(path: "ModeConfigurations.json")
              ),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = root["data"] as? [[String: Any]]
        else { return }

        for entry in dataArray {
            guard let configs = entry["modeConfigurations"] as? [String: Any] else { continue }
            for (identifier, value) in configs {
                guard let config = value as? [String: Any],
                      let mode = config["mode"] as? [String: Any]
                else { continue }
                let name = mode["name"] as? String ?? Self.fallbackName(for: identifier)
                let symbol = mode["symbolImageName"] as? String ?? "moon.fill"
                modeNames[identifier] = (name, symbol)
            }
        }
    }

    private static func activeModeIdentifier(in assertionsData: Data) -> String? {
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

    private static func fallbackName(for identifier: String) -> String {
        if identifier.contains("default") { return "Do Not Disturb" }
        if identifier.contains("sleep") { return "Sleep" }
        return identifier.components(separatedBy: ".").last?.capitalized ?? "Focus"
    }
}

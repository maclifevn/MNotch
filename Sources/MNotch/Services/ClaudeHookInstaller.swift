import Foundation

/// Installs / removes MNotch's hook entries in ~/.claude/settings.json.
///
/// Every hook entry MNotch adds carries a marker key so uninstall can strip
/// exactly what we added and leave the user's own hooks untouched. The relay
/// script is copied into Application Support (a stable path independent of the
/// .app location) and referenced by absolute path.
@MainActor
enum ClaudeHookInstaller {
    private static let marker = "__mnotch__"

    /// Hook events we register. Permission events block; the rest notify.
    private static let events = [
        "PreToolUse", "PermissionRequest", "Notification",
        "Stop", "SessionStart", "SessionEnd",
    ]

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json")
    }

    static var relayURL: URL {
        AgentServer.supportDirectory.appending(path: "mnotch-relay.pl")
    }

    static var isInstalled: Bool {
        guard let root = readSettings(),
              let hooks = root["hooks"] as? [String: Any]
        else { return false }
        for event in events {
            if let matchers = hooks[event] as? [[String: Any]],
               matchers.contains(where: { isOurs($0) }) {
                return true
            }
        }
        return false
    }

    static func install() throws {
        try copyRelay()

        var root = readSettings() ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        let command = "/usr/bin/perl '\(relayURL.path)'"
        let hookEntry: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 600,
            marker: true,
        ]

        for event in events {
            var matchers = hooks[event] as? [[String: Any]] ?? []
            matchers.removeAll(where: isOurs)   // idempotent
            matchers.append([
                "matcher": "*",
                "hooks": [hookEntry],
                marker: true,
            ])
            hooks[event] = matchers
        }

        root["hooks"] = hooks
        try writeSettings(root)
        mnotchLog.notice("Claude hooks installed")
    }

    static func uninstall() throws {
        guard var root = readSettings(),
              var hooks = root["hooks"] as? [String: Any]
        else { return }

        for event in events {
            guard var matchers = hooks[event] as? [[String: Any]] else { continue }
            matchers.removeAll(where: isOurs)
            if matchers.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = matchers
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try writeSettings(root)
        mnotchLog.notice("Claude hooks uninstalled")
    }

    // MARK: - Helpers

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry[marker] as? Bool) == true
    }

    private static func copyRelay() throws {
        guard let bundled = Bundle.main.url(
            forResource: "mnotch-relay", withExtension: "pl"
        ) else {
            throw NSError(domain: "MNotch", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Bundled relay script missing",
            ])
        }
        let dest = relayURL
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: bundled, to: dest)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dest.path
        )
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return json as? [String: Any]
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL)
    }
}

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

    static var quotaRelayURL: URL {
        AgentServer.supportDirectory.appending(path: "mnotch-claude-statusline.pl")
    }

    private static var statusLineBackupURL: URL {
        AgentServer.supportDirectory.appending(path: "claude-statusline-backup.json")
    }

    private static var statusLineCommandURL: URL {
        AgentServer.supportDirectory.appending(path: "claude-statusline-command")
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

    static var isQuotaBridgeInstalled: Bool {
        guard let statusLine = readSettings()?["statusLine"] as? [String: Any]
        else { return false }
        return isOurStatusLine(statusLine)
    }

    /// Keep the deployed relay + notifier in sync with the running app, so a
    /// rebuilt app doesn't leave a stale relay behind the installed hooks.
    /// It also repairs a missing quota bridge when MNotch hooks are installed.
    static func refreshScripts() {
        try? deployScripts()
        if isInstalled, !isQuotaBridgeInstalled {
            try? installQuotaBridge()
        }
    }

    static func deployScripts() throws {
        try copyRelay()
        try copyQuotaRelay()
        ensureNotifyHelper()
    }

    /// Copy the generic notifier next to the relay so the path shown in
    /// settings (for Codex/Gemini) actually exists.
    static func ensureNotifyHelper() {
        guard let bundled = Bundle.main.url(
            forResource: "mnotch-notify", withExtension: "pl"
        ) else { return }
        let dest = AgentServer.supportDirectory.appending(path: "mnotch-notify.pl")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: bundled, to: dest)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dest.path
        )
    }

    static func install() throws {
        try deployScripts()

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
        try installQuotaBridge(into: &root)
        try writeSettings(root)
        mnotchLog.notice("Claude hooks + quota bridge installed")
    }

    static func uninstall() throws {
        guard var root = readSettings() else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

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
        restoreQuotaBridge(in: &root)
        try writeSettings(root)
        removeStatusLineBackup()
        mnotchLog.notice("Claude hooks + quota bridge uninstalled")
    }

    static func installQuotaBridge() throws {
        try deployScripts()
        var root = readSettings() ?? [:]
        try installQuotaBridge(into: &root)
        try writeSettings(root)
    }

    // MARK: - Helpers

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry[marker] as? Bool) == true
    }

    private static func isOurStatusLine(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        return command.contains("mnotch-claude-statusline.pl")
    }

    private static func installQuotaBridge(into root: inout [String: Any]) throws {
        if let current = root["statusLine"] as? [String: Any],
           isOurStatusLine(current) {
            return
        }

        let previous = root["statusLine"] as? [String: Any]
        try saveStatusLineBackup(previous)

        var replacement: [String: Any] = [
            "type": "command",
            "command": "/usr/bin/perl \(shellQuote(quotaRelayURL.path))",
        ]
        // Preserve the supported presentation/timing options while the
        // wrapper is active, then restore the complete object on uninstall.
        for key in ["padding", "refreshInterval", "hideVimModeIndicator"] {
            if let value = previous?[key] { replacement[key] = value }
        }
        root["statusLine"] = replacement
    }

    private static func restoreQuotaBridge(in root: inout [String: Any]) {
        guard let current = root["statusLine"] as? [String: Any],
              isOurStatusLine(current)
        else { return }
        if let data = try? Data(contentsOf: statusLineBackupURL),
           let previous = try? JSONSerialization.jsonObject(with: data) {
            root["statusLine"] = previous
        } else {
            root.removeValue(forKey: "statusLine")
        }
    }

    private static func saveStatusLineBackup(_ previous: [String: Any]?) throws {
        removeStatusLineBackup()
        guard let previous else { return }
        let data = try JSONSerialization.data(
            withJSONObject: previous,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: statusLineBackupURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: statusLineBackupURL.path
        )
        if let command = previous["command"] as? String, !command.isEmpty {
            try command.write(to: statusLineCommandURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: statusLineCommandURL.path
            )
        }
    }

    private static func removeStatusLineBackup() {
        try? FileManager.default.removeItem(at: statusLineBackupURL)
        try? FileManager.default.removeItem(at: statusLineCommandURL)
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

    private static func copyQuotaRelay() throws {
        guard let bundled = Bundle.main.url(
            forResource: "mnotch-claude-statusline", withExtension: "pl"
        ) else {
            throw NSError(domain: "MNotch", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Bundled Claude quota relay missing",
            ])
        }
        let dest = quotaRelayURL
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: bundled, to: dest)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dest.path
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
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
        try data.write(to: settingsURL, options: .atomic)
    }
}

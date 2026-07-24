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

    /// Hook events we register. Only `PermissionRequest` blocks — it fires
    /// solely when a tool would otherwise prompt the user, so read-only tools
    /// (Read/Grep/Glob…) never reach the notch. `PreToolUse` fires on *every*
    /// tool call and is deliberately NOT registered (see `retiredEvents`).
    private static let events = [
        "PermissionRequest", "Notification",
        "Stop", "SessionStart", "SessionEnd",
    ]

    /// Events MNotch used to install but no longer does. Kept here so upgrades
    /// strip the stale entries out of an existing settings.json.
    private static let retiredEvents = ["PreToolUse"]

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json")
    }

    static var relayURL: URL {
        AgentServer.supportDirectory.appending(path: "mnotch-relay.pl")
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

    /// Keep the deployed relay + notifier in sync with the running app, so a
    /// rebuilt app doesn't leave a stale relay behind the installed hooks.
    /// Also removes the retired status-line quota wrapper from older installs.
    static func refreshScripts() {
        retireQuotaBridge()
        if isInstalled {
            try? deployScripts()
            // Migrate installs that predate the PreToolUse → PermissionRequest
            // switch, so read-only tools stop popping the notch on every call.
            pruneRetiredEvents()
        }
    }

    /// Strip our markers from any event in `retiredEvents` (currently the old
    /// PreToolUse hook). Idempotent; writes only when something changed.
    private static func pruneRetiredEvents() {
        guard var root = readSettings(),
              var hooks = root["hooks"] as? [String: Any]
        else { return }
        var changed = false
        for event in retiredEvents {
            guard var matchers = hooks[event] as? [[String: Any]] else { continue }
            let before = matchers.count
            matchers.removeAll(where: isOurs)
            guard matchers.count != before else { continue }
            changed = true
            if matchers.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = matchers
            }
        }
        guard changed else { return }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try? writeSettings(root)
        mnotchLog.notice("Pruned retired PreToolUse hook from settings.json")
    }

    static func deployScripts() throws {
        try copyRelay()
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

        // Clean up hooks from older installs we no longer register.
        for event in retiredEvents {
            guard var matchers = hooks[event] as? [[String: Any]] else { continue }
            matchers.removeAll(where: isOurs)
            if matchers.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = matchers
            }
        }

        root["hooks"] = hooks
        try writeSettings(root)
        mnotchLog.notice("Claude hooks installed")
    }

    static func uninstall() throws {
        guard var root = readSettings() else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for event in events + retiredEvents {
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
        (root, _) = restoringRetiredQuotaBridge(
            in: root,
            backupData: try? Data(contentsOf: statusLineBackupURL)
        )
        try writeSettings(root)
        cleanupRetiredQuotaFiles()
        mnotchLog.notice("Claude hooks uninstalled")
    }

    // MARK: - Helpers

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry[marker] as? Bool) == true
    }

    private static func isOurStatusLine(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        return command.contains("mnotch-claude-statusline.pl")
    }

    /// One-time migration for builds that installed MNotch as Claude's status
    /// line. Restore the user's complete previous object before deleting our
    /// retired helper files.
    static func restoringRetiredQuotaBridge(
        in source: [String: Any],
        backupData: Data?
    ) -> (root: [String: Any], restored: Bool) {
        guard let current = source["statusLine"] as? [String: Any],
              isOurStatusLine(current)
        else { return (source, false) }

        var root = source
        if let backupData,
           let previous = try? JSONSerialization.jsonObject(with: backupData) as? [String: Any] {
            root["statusLine"] = previous
        } else {
            root.removeValue(forKey: "statusLine")
        }
        return (root, true)
    }

    private static func cleanupRetiredQuotaFiles() {
        try? FileManager.default.removeItem(at: statusLineBackupURL)
        try? FileManager.default.removeItem(at: statusLineCommandURL)
        try? FileManager.default.removeItem(
            at: AgentServer.supportDirectory.appending(path: "mnotch-claude-statusline.pl")
        )
        try? FileManager.default.removeItem(
            at: AgentServer.supportDirectory.appending(path: "claude-quota.json")
        )
    }

    private static func retireQuotaBridge() {
        guard let root = readSettings() else { return }
        let result = restoringRetiredQuotaBridge(
            in: root,
            backupData: try? Data(contentsOf: statusLineBackupURL)
        )
        guard result.restored else {
            cleanupRetiredQuotaFiles()
            return
        }
        do {
            try writeSettings(result.root)
            cleanupRetiredQuotaFiles()
            mnotchLog.notice("Retired Claude quota status-line bridge")
        } catch {
            // Preserve both the wrapper and its backup if the atomic settings
            // write fails; a later launch can safely retry the migration.
            mnotchLog.error("Could not retire Claude status-line bridge: \(error)")
        }
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
        try data.write(to: settingsURL, options: .atomic)
    }
}

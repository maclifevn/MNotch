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
        try? HookConfiguration.deploy(bundled, to: dest)
    }

    static func install() throws {
        var root = try HookConfiguration.read(settingsURL) ?? [:]
        try deployScripts()
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        let command = "/usr/bin/perl \(HookConfiguration.shellQuote(relayURL.path))"
        let hookEntry: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 65,
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
        let migration = restoringRetiredQuotaBridge(
            in: root,
            backupData: try quotaBackupData(for: root)
        )
        try writeSettings(migration.root)
        if migration.restored { cleanupRetiredQuotaFiles() }
        mnotchLog.notice("Claude hooks uninstalled")
    }

    // MARK: - Helpers

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry[marker] as? Bool) == true
    }

    private static var legacyStatusLineCommand: String {
        let helper = AgentServer.supportDirectory.appending(path: "mnotch-claude-statusline.pl")
        return "/usr/bin/perl \(HookConfiguration.shellQuote(helper.path))"
    }

    private static func isOurStatusLine(_ entry: [String: Any], command expected: String? = nil) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        return command == (expected ?? legacyStatusLineCommand)
    }

    private static func quotaBackupData(for root: [String: Any]) throws -> Data? {
        guard let current = root["statusLine"] as? [String: Any], isOurStatusLine(current),
              FileManager.default.fileExists(atPath: statusLineBackupURL.path)
        else { return nil }
        return try BoundedFileReader.read(statusLineBackupURL, limit: 2 * 1_024 * 1_024)
    }

    /// One-time migration for builds that installed MNotch as Claude's status
    /// line. Restore the user's complete previous object before deleting our
    /// retired helper files.
    static func restoringRetiredQuotaBridge(
        in source: [String: Any],
        backupData: Data?,
        legacyCommand: String? = nil
    ) -> (root: [String: Any], restored: Bool) {
        guard let current = source["statusLine"] as? [String: Any],
              isOurStatusLine(current, command: legacyCommand)
        else { return (source, false) }

        var root = source
        if let backupData {
            // A corrupt backup is still user data. Keep both the current
            // configuration and the backup so it can be repaired or retried.
            guard backupData.count <= 2 * 1_024 * 1_024,
                  let previous = try? JSONSerialization.jsonObject(with: backupData) as? [String: Any]
            else { return (source, false) }
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
        do {
            let result = restoringRetiredQuotaBridge(in: root, backupData: try quotaBackupData(for: root))
            // A custom command may still use these files. Only remove them
            // after a migration whose ownership and backup were verified.
            guard result.restored else { return }
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
        try HookConfiguration.deploy(bundled, to: dest)
    }

    private static func readSettings() -> [String: Any]? {
        try? HookConfiguration.read(settingsURL)
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

import Foundation

/// Installs MNotch's blocking approval relay as user-level Codex hooks.
/// Codex requires users to review/trust changed command hooks via `/hooks`;
/// MNotch deliberately doesn't modify Codex's trust database.
@MainActor
enum CodexHookInstaller {
    private static let events = ["PermissionRequest", "SessionStart", "Stop"]

    static var codexHome: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"],
           path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
    }

    static var hooksURL: URL { codexHome.appending(path: "hooks.json") }

    static var isInstalled: Bool {
        guard let root = readHooks(),
              let hooks = root["hooks"] as? [String: Any]
        else { return false }
        return events.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains(where: isOurs) == true
            }
        }
    }

    static func install() throws {
        var root = try HookConfiguration.read(hooksURL) ?? [:]
        try ClaudeHookInstaller.deployScripts()
        root = installing(into: root, command: relayCommand)
        try writeHooks(root)
        mnotchLog.notice("Codex hooks installed; trust review required in /hooks")
    }

    static func uninstall() throws {
        guard let root = readHooks() else { return }
        try writeHooks(uninstalling(from: root))
        mnotchLog.notice("Codex hooks uninstalled")
    }

    static func installing(
        into root: [String: Any],
        command: String
    ) -> [String: Any] {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = removingOurs(from: groups, command: command)
            let blocking = event == "PermissionRequest"
            let handler: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": blocking ? 65 : 10,
                "statusMessage": blocking
                    ? "Waiting for MNotch approval"
                    : "Notifying MNotch",
            ]
            groups.append([
                "matcher": "*",
                "hooks": [handler],
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    static func uninstalling(from root: [String: Any], command: String? = nil) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let remaining = removingOurs(from: groups, command: command ?? relayCommand)
            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = remaining
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return root
    }

    private static var relayCommand: String {
        "/usr/bin/perl \(shellQuote(ClaudeHookInstaller.relayURL.path)) codex"
    }

    private static func shellQuote(_ value: String) -> String {
        HookConfiguration.shellQuote(value)
    }

    private static func isOurs(_ handler: [String: Any]) -> Bool {
        guard let command = handler["command"] as? String else { return false }
        return command == relayCommand
    }

    private static func removingOurs(
        from groups: [[String: Any]], command: String
    ) -> [[String: Any]] {
        groups.compactMap { group in
            guard var handlers = group["hooks"] as? [[String: Any]] else { return group }
            handlers.removeAll { ($0["command"] as? String) == command }
            guard !handlers.isEmpty else { return nil }
            var group = group
            group["hooks"] = handlers
            return group
        }
    }

    private static func readHooks() -> [String: Any]? {
        try? HookConfiguration.read(hooksURL)
    }

    private static func writeHooks(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: hooksURL, options: .atomic)
    }
}

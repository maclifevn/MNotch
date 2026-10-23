import Foundation

enum HookConfiguration {
    enum ConfigurationError: LocalizedError {
        case invalid, tooLarge
        var errorDescription: String? {
            L10n.string("Existing hook configuration is invalid or too large. Repair it before installing hooks; MNotch has left it unchanged.")
        }
    }

    static func read(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { throw ConfigurationError.invalid }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 2 * 1_024 * 1_024 + 1) ?? Data()
        guard data.count <= 2 * 1_024 * 1_024 else { throw ConfigurationError.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ConfigurationError.invalid }
        if let rawHooks = root["hooks"] {
            guard let hooks = rawHooks as? [String: Any] else { throw ConfigurationError.invalid }
            for value in hooks.values {
                guard let groups = value as? [[String: Any]] else { throw ConfigurationError.invalid }
                for group in groups where group["hooks"] != nil {
                    guard group["hooks"] is [[String: Any]] else { throw ConfigurationError.invalid }
                }
            }
        }
        return root
    }

    static func deploy(_ source: URL, to destination: URL) throws {
        // Keep the previous working script if copying or disk allocation fails.
        try Data(contentsOf: source).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

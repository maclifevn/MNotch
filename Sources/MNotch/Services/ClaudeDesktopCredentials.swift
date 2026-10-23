import CommonCrypto
import CoreFoundation
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SQLite3

/// Reads Claude Desktop's existing encrypted OAuth cache. Nothing is minted,
/// refreshed, copied to another store, or written back to Claude's files.
enum ClaudeDesktopCredentials {
    enum ConnectionResult: Sendable {
        case connected, permissionRequired, signInRequired, unavailable
    }

    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    static var isAvailable: Bool {
        FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("config.json").path)
    }

    private static let passwordLock = NSLock()
    private nonisolated(unsafe) static var approvedPassword: Data?

    private static func savedPassword() -> Data? {
        passwordLock.lock()
        defer { passwordLock.unlock() }
        return approvedPassword
    }

    private static func rememberPassword(_ password: Data) {
        passwordLock.lock()
        defer { passwordLock.unlock() }
        approvedPassword = password
    }

    /// Polling is always silent. Only the explicit Connect button can ask the
    /// user to approve Keychain access for MNotch's stable signing identity.
    static func accessTokens() -> [String] {
        guard let configuration = try? BoundedFileReader.read(
            directory.appendingPathComponent("config.json"), limit: 1_024 * 1_024
        ), hasCache(configuration),
              let password = savedPassword() ?? ClaudeCredentialKeychain.read(service: "Claude Safe Storage").data else { return [] }
        return accessTokens(
            configuration: configuration, password: password,
            organizationID: activeOrganization(password: password)
        )
    }

    static func connect() async -> ConnectionResult {
        await Task.detached(priority: .userInitiated) {
            guard let configuration = try? BoundedFileReader.read(
                directory.appendingPathComponent("config.json"), limit: 1_024 * 1_024
            ), hasCache(configuration) else { return .signInRequired }
            let result = ClaudeCredentialKeychain.read(service: "Claude Safe Storage", allowInteraction: true)
            guard let password = result.data else {
                return result.status == errSecItemNotFound ? .signInRequired : .permissionRequired
            }
            let tokens = accessTokens(
                configuration: configuration, password: password,
                organizationID: activeOrganization(password: password)
            )
            guard !tokens.isEmpty else { return .signInRequired }
            // A one-use Allow must work for this run too. Keep only the
            // approved decryption key in memory; re-read Claude's actual cache
            // every poll so sign-out and account changes remain authoritative.
            rememberPassword(password)
            return .connected
        }.value
    }

    private static func hasCache(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return root["oauth:tokenCacheV2"] is String || root["oauth:tokenCache"] is String
    }

    static func accessTokens(
        configuration: Data, password: Data, organizationID: String? = nil, now: Date = .now
    ) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              let accountID = root["lastKnownAccountUuid"] as? String else { return [] }
        // V2 tombstones/invalidations are authoritative. Falling back to V1
        // when V2 exists could resurrect a credential the user signed out of.
        let key = root.keys.contains("oauth:tokenCacheV2") ? "oauth:tokenCacheV2" : "oauth:tokenCache"
        guard let encoded = root[key] as? String,
              let encrypted = Data(base64Encoded: encoded),
              let plaintext = decrypt(encrypted, password: password) else { return [] }
        return parseCache(plaintext, accountID: accountID, organizationID: organizationID, now: now)
    }

    static func parseCache(
        _ plaintext: Data, accountID: String, organizationID: String?, now: Date
    ) -> [String] {
        guard let account = UUID(uuidString: accountID),
              let root = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else { return [] }
        let selectedOrganization = organizationID.flatMap(UUID.init(uuidString:))
        if organizationID != nil, selectedOrganization == nil { return [] }
        var candidates: [(organization: UUID, token: String, expires: Double)] = []
        for (key, raw) in root {
            guard key.hasPrefix("acct:"), let separator = key.firstIndex(of: "|"),
                  UUID(uuidString: String(key[key.index(key.startIndex, offsetBy: 5)..<separator])) == account,
                  let entry = raw as? [String: Any],
                  let token = entry["token"] as? String, token.hasPrefix("sk-ant-oat"),
                  token.utf8.count <= 16_384, token.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
                  let expiry = entry["expiresAt"] as? NSNumber,
                  CFGetTypeID(expiry) != CFBooleanGetTypeID(), expiry.doubleValue.isFinite,
                  expiry.doubleValue / 1_000 > now.timeIntervalSince1970 else { continue }
            let configuration = String(key[key.index(after: separator)...])
            guard let host = configuration.range(of: ":https://api.anthropic.com:"),
                  configuration[host.upperBound...].split(separator: " ").contains("user:profile") else { continue }
            let identity = configuration[..<host.lowerBound].split(separator: ":", omittingEmptySubsequences: false)
            guard identity.count == 2, UUID(uuidString: String(identity[0])) != nil,
                  let organization = UUID(uuidString: String(identity[1])),
                  selectedOrganization == nil || selectedOrganization == organization else { continue }
            candidates.append((organization, token, expiry.doubleValue))
        }
        // Without an active-org cookie, one unambiguous org is safe. Never
        // silently show another organization's subscription limits.
        guard Set(candidates.map(\.organization)).count <= 1 else { return [] }
        var seen = Set<String>()
        return Array(candidates.sorted { $0.expires > $1.expires }.compactMap {
            seen.insert($0.token).inserted ? $0.token : nil
        }.prefix(4))
    }

    /// Electron's macOS v10 safeStorage format: PBKDF2-SHA1 and AES-128-CBC.
    /// Crypto primitives come from CommonCrypto; a wrong key/format fails closed.
    static func decrypt(_ encrypted: Data, password: Data) -> Data? {
        guard !password.isEmpty, password.count <= 4_096,
              encrypted.count > 3, encrypted.count <= 1_024 * 1_024,
              encrypted.starts(with: Data("v10".utf8)),
              (encrypted.count - 3).isMultiple(of: kCCBlockSizeAES128) else { return nil }
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derived = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBufferPointer { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    password.count, saltBytes.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1_003, &key, key.count
                )
            }
        }
        guard derived == kCCSuccess else { return nil }
        defer { key.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let ciphertext = Data(encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                ciphertext.withUnsafeBytes { inputBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inputBytes.baseAddress, ciphertext.count, outputBytes.baseAddress, outputBytes.count, &written
                        )
                    }
                }
            }
        }
        defer { output.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard status == kCCSuccess else { return nil }
        return Data(output.prefix(written))
    }

    static func cookieValue(_ encrypted: Data, host: String, schemaVersion: Int, password: Data) -> String? {
        guard let plaintext = decrypt(encrypted, password: password) else { return nil }
        if schemaVersion >= 24 {
            let digest = Data(SHA256.hash(data: Data(host.utf8)))
            guard plaintext.count >= digest.count, plaintext.starts(with: digest) else { return nil }
            return String(data: plaintext.dropFirst(digest.count), encoding: .utf8)
        }
        return String(data: plaintext, encoding: .utf8)
    }

    private static func activeOrganization(password: Data) -> String? {
        var database: OpaquePointer?
        let file = directory.appendingPathComponent("Cookies")
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 200)
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key = 'version'", -1, &versionStatement, nil) == SQLITE_OK,
              let versionStatement else { return nil }
        defer { sqlite3_finalize(versionStatement) }
        guard sqlite3_step(versionStatement) == SQLITE_ROW else { return nil }
        let version = Int(sqlite3_column_int(versionStatement, 0))
        var statement: OpaquePointer?
        // Only the active-organization preference is needed; session/auth and
        // unrelated browser cookies are deliberately not selected.
        let query = "SELECT host_key, value, encrypted_value FROM cookies WHERE name = 'lastActiveOrg' AND host_key IN ('.claude.ai', 'claude.ai', '.claude.com', 'claude.com') ORDER BY last_access_utc DESC LIMIT 4"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let hostBytes = sqlite3_column_text(statement, 0) else { continue }
            let host = String(cString: hostBytes)
            let size = Int(sqlite3_column_bytes(statement, 2))
            var organization: String?
            if size > 0, size <= 4_096, let bytes = sqlite3_column_blob(statement, 2) {
                organization = cookieValue(Data(bytes: bytes, count: size), host: host, schemaVersion: version, password: password)
            } else if let value = sqlite3_column_text(statement, 1) {
                organization = String(cString: value)
            }
            if let organization, let id = UUID(uuidString: organization) { return id.uuidString }
        }
        return nil
    }
}

/// One lock covers both legacy Keychain lookups and explicit UI access, since
/// SecKeychain's interaction setting is process-wide rather than per request.
enum ClaudeCredentialKeychain {
    struct Result { let status: OSStatus; let data: Data? }
    private static let lock = NSLock()

    static func read(service: String, allowInteraction: Bool = false) -> Result {
        lock.lock()
        defer { lock.unlock() }
        var wasAllowed: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&wasAllowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(allowInteraction) == errSecSuccess else {
            return Result(status: errSecInteractionNotAllowed, data: nil)
        }
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        var item: CFTypeRef?
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return Result(status: status, data: status == errSecSuccess ? item as? Data : nil)
    }
}

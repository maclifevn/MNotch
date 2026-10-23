import Foundation
import XCTest
@testable import MNotch

final class ClaudeDesktopCredentialsTests: XCTestCase {
    func testDecryptsIndependentElectronV10Fixture() throws {
        let encrypted = try XCTUnwrap(Data(base64Encoded: Fixture.text))
        let plaintext = try XCTUnwrap(ClaudeDesktopCredentials.decrypt(encrypted, password: Fixture.password))
        XCTAssertEqual(String(data: plaintext, encoding: .utf8), #"{"fixture":"MNotch synthetic data","value":42}"#)
    }

    func testDecryptRejectsUnsupportedVersionTruncationAndWrongPassword() throws {
        let encrypted = try XCTUnwrap(Data(base64Encoded: Fixture.text))
        var unsupported = encrypted
        unsupported.replaceSubrange(0..<3, with: Data("v11".utf8))
        XCTAssertNil(ClaudeDesktopCredentials.decrypt(unsupported, password: Fixture.password))
        XCTAssertNil(ClaudeDesktopCredentials.decrypt(Data(encrypted.dropLast()), password: Fixture.password))
        XCTAssertNil(ClaudeDesktopCredentials.decrypt(Data("v10".utf8), password: Fixture.password))
        XCTAssertNil(ClaudeDesktopCredentials.decrypt(Data(), password: Fixture.password))
        // CBC has no authentication tag; an incorrect key can coincidentally
        // have valid padding. Cache parsing and cookie host binding below
        // reject its output rather than assuming decryption always fails.
        XCTAssertNotEqual(
            ClaudeDesktopCredentials.decrypt(encrypted, password: Data("wrong-test-password".utf8)),
            Data(#"{"fixture":"MNotch synthetic data","value":42}"#.utf8)
        )
    }

    func testCacheSelectsOnlyCurrentAccountOfficialHostAndProfileScope() throws {
        let token = "sk-ant-oat01-selected"
        let entries: [String: Any] = [
            key(): entry(token),
            key(accountID: Fixture.otherAccountID): entry("sk-ant-oat01-other-account"),
            key(accountID: nil): entry("sk-ant-oat01-unscoped-account"),
            key(host: "http://api.anthropic.com"): entry("sk-ant-oat01-insecure-host"),
            key(host: "https://api.anthropic.com.evil.example"): entry("sk-ant-oat01-lookalike-host"),
            key(host: "https://api-staging.anthropic.com"): entry("sk-ant-oat01-staging"),
            key(scope: "user:inference user:file_upload"): entry("sk-ant-oat01-no-profile"),
            key(scope: "user:profile_extra"): entry("sk-ant-oat01-lookalike-scope"),
            key(clientID: "not-a-uuid"): entry("sk-ant-oat01-invalid-client"),
        ]
        XCTAssertEqual(try parse(entries), [token])
    }

    func testCacheIgnoresTombstonesExpiredAndMalformedEntries() throws {
        let nowMilliseconds = Fixture.now.timeIntervalSince1970 * 1_000
        let invalidEntries: [Any] = [
            NSNull(), [:], "not an entry",
            ["token": "sk-ant-oat01-expired", "expiresAt": nowMilliseconds - 1],
            ["token": "sk-ant-oat01-expiring-now", "expiresAt": nowMilliseconds],
            ["token": "sk-ant-oat01-expired-marker", "expiresAt": 0],
            ["token": "sk-ant-oat01-numeric-string", "expiresAt": "2000000000000"],
            ["token": "sk-ant-oat01-boolean-date", "expiresAt": true],
            ["token": "sk-ant-oat01-no-expiry"],
            ["token": 123, "expiresAt": Fixture.expiry],
            ["expiresAt": Fixture.expiry],
        ]
        for value in invalidEntries {
            XCTAssertEqual(try parse([key(): value]), [])
        }
        for token in ["", "not-a-token", "sk-ant-api03-not-oauth",
                      "sk-ant-oat01-has space", "sk-ant-oat01-has\nnewline"] {
            XCTAssertEqual(try parse([key(): entry(token)]), [])
        }
        for text in ["not JSON", "null", "[]"] {
            XCTAssertEqual(ClaudeDesktopCredentials.parseCache(
                Data(text.utf8), accountID: Fixture.accountID, organizationID: nil, now: Fixture.now
            ), [])
        }
    }

    func testCacheSortsByExpiryAndDeduplicatesTokensWithoutScopePreference() throws {
        let entries: [String: Any] = [
            key(): entry("sk-ant-oat01-shared", expiresAt: Fixture.expiry),
            key(scope: "user:profile"): entry("sk-ant-oat01-newest", expiresAt: Fixture.expiry + 300_000),
            key(scope: "user:profile user:inference"): entry(
                "sk-ant-oat01-shared", expiresAt: Fixture.expiry + 100_000
            ),
        ]
        XCTAssertEqual(try parse(entries), ["sk-ant-oat01-newest", "sk-ant-oat01-shared"])
    }

    func testMultipleOrganizationsRequireExplicitSelection() throws {
        let entries: [String: Any] = [
            key(): entry("sk-ant-oat01-first-org"),
            key(organizationID: Fixture.otherOrganizationID): entry("sk-ant-oat01-second-org"),
        ]
        XCTAssertEqual(try parse(entries), [])
        XCTAssertEqual(try parse(entries, organizationID: Fixture.organizationID), ["sk-ant-oat01-first-org"])
        XCTAssertEqual(try parse(entries, organizationID: Fixture.otherOrganizationID), ["sk-ant-oat01-second-org"])
        XCTAssertEqual(try parse(entries, organizationID: Fixture.otherAccountID), [])
    }

    func testConfigurationReadsEncryptedCacheWithoutRunningDesktopOrCode() throws {
        let configuration = try config(v2: Fixture.current)
        XCTAssertEqual(ClaudeDesktopCredentials.accessTokens(
            configuration: configuration, password: Fixture.password, now: Fixture.now
        ), ["sk-ant-oat01-fixture-current-account"])
        XCTAssertEqual(ClaudeDesktopCredentials.accessTokens(
            configuration: configuration, password: Fixture.password,
            organizationID: Fixture.otherOrganizationID, now: Fixture.now
        ), [])
        XCTAssertEqual(ClaudeDesktopCredentials.accessTokens(
            configuration: configuration, password: Data("wrong-test-password".utf8), now: Fixture.now
        ), [])
    }

    func testConfigurationUsesLegacyCacheOnlyWhenV2KeyIsAbsent() throws {
        let legacyOnly = try config(legacy: Fixture.legacy)
        XCTAssertEqual(ClaudeDesktopCredentials.accessTokens(
            configuration: legacyOnly, password: Fixture.password, now: Fixture.now
        ), ["sk-ant-oat01-legacy-fixture"])
        let both = try config(v2: Fixture.current, legacy: Fixture.legacy)
        XCTAssertEqual(ClaudeDesktopCredentials.accessTokens(
            configuration: both, password: Fixture.password, now: Fixture.now
        ), ["sk-ant-oat01-fixture-current-account"])
    }

    func testV2TombstonesOrInvalidDataNeverReviveLegacyCredentials() throws {
        for v2: Any in [Fixture.tombstone, NSNull(), "", "not-base64"] {
            let configuration = try config(v2: v2, legacy: Fixture.legacy)
            XCTAssertEqual(ClaudeDesktopCredentials.accessTokens(
                configuration: configuration, password: Fixture.password, now: Fixture.now
            ), [])
        }
    }

    func testConfigurationRequiresCurrentAccountIdentity() throws {
        for account: Any in [NSNull(), "", Fixture.otherAccountID] {
            let configuration = try JSONSerialization.data(withJSONObject: [
                "lastKnownAccountUuid": account, "oauth:tokenCacheV2": Fixture.current,
            ])
            XCTAssertEqual(ClaudeDesktopCredentials.accessTokens(
                configuration: configuration, password: Fixture.password, now: Fixture.now
            ), [])
        }
        XCTAssertEqual(ClaudeDesktopCredentials.accessTokens(
            configuration: Data("not JSON".utf8), password: Fixture.password, now: Fixture.now
        ), [])
    }

    func testCookieSchema24VerifiesAndStripsHostDigest() throws {
        let encrypted = try XCTUnwrap(Data(base64Encoded: Fixture.cookieV24))
        XCTAssertEqual(ClaudeDesktopCredentials.cookieValue(
            encrypted, host: ".claude.ai", schemaVersion: 24, password: Fixture.password
        ), "synthetic-cookie-value")
        XCTAssertEqual(ClaudeDesktopCredentials.cookieValue(
            encrypted, host: ".claude.ai", schemaVersion: 25, password: Fixture.password
        ), "synthetic-cookie-value")
        XCTAssertNil(ClaudeDesktopCredentials.cookieValue(
            encrypted, host: "claude.ai", schemaVersion: 24, password: Fixture.password
        ))
        XCTAssertNil(ClaudeDesktopCredentials.cookieValue(
            encrypted, host: ".example.com", schemaVersion: 24, password: Fixture.password
        ))
    }

    func testLegacyCookieHasNoHostDigestAndCannotMasqueradeAsSchema24() throws {
        let encrypted = try XCTUnwrap(Data(base64Encoded: Fixture.cookieLegacy))
        XCTAssertEqual(ClaudeDesktopCredentials.cookieValue(
            encrypted, host: ".claude.ai", schemaVersion: 23, password: Fixture.password
        ), "synthetic-cookie-value")
        XCTAssertNil(ClaudeDesktopCredentials.cookieValue(
            encrypted, host: ".claude.ai", schemaVersion: 24, password: Fixture.password
        ))
    }

    private func key(
        accountID: String? = Fixture.accountID,
        organizationID: String = Fixture.organizationID,
        clientID: String = Fixture.clientID,
        host: String = "https://api.anthropic.com",
        scope: String = "user:inference user:file_upload user:profile"
    ) -> String {
        let prefix = accountID.map { "acct:\($0)|" } ?? ""
        return "\(prefix)\(clientID):\(organizationID):\(host):\(scope)"
    }

    private func entry(_ token: String, expiresAt: Double = Fixture.expiry) -> [String: Any] {
        ["token": token, "expiresAt": expiresAt]
    }

    private func parse(_ entries: [String: Any], organizationID: String? = nil) throws -> [String] {
        ClaudeDesktopCredentials.parseCache(
            try JSONSerialization.data(withJSONObject: entries),
            accountID: Fixture.accountID, organizationID: organizationID, now: Fixture.now
        )
    }

    private func config(v2: Any? = nil, legacy: String? = nil) throws -> Data {
        var value: [String: Any] = ["lastKnownAccountUuid": Fixture.accountID]
        if let v2 { value["oauth:tokenCacheV2"] = v2 }
        if let legacy { value["oauth:tokenCache"] = legacy }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private enum Fixture {
        static let accountID = "11111111-1111-4111-8111-111111111111"
        static let otherAccountID = "33333333-3333-4333-8333-333333333333"
        static let organizationID = "22222222-2222-4222-8222-222222222222"
        static let otherOrganizationID = "44444444-4444-4444-8444-444444444444"
        static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        static let password = Data("mnotch-independent-test-password".utf8)
        static let now = Date(timeIntervalSince1970: 1_900_000_000)
        static let expiry: Double = 2_000_000_000_000

        // Generated independently with Node's crypto builtin:
        // key = pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1')
        // cipher = createCipheriv('aes-128-cbc', key, Buffer.alloc(16, 0x20))
        // fixture = concat(Buffer.from('v10'), cipher.update(plaintext), cipher.final()).toString('base64')
        // Schema-24 cookie plaintext is concat(sha256('.claude.ai'), UTF8(cookieValue)).
        static let text = "djEwj7bbK3Ea3/l6jhCGx0epgWvB7nIuUI+tub1ySC5gp0EWQPhESTTRTwHYsQGh5EzB"
        static let current = "djEw+CEUYkkrlig/PqBWK46SXZTnbOVrC5FxBhg5AkJ3CXx6FQODGs5P9qtl7HrstfnLKBcAsK3M6K3QuYCNQwytdAlEvb5d2Hz/QpOpjFNfRaG+602u+cAiAyOs8EBqSo5F0a05+lPHPfhNhO/cZxGKB8EUiXanWCl/kVwf7Gw5NYb/mr3MqJ7vlD9Myo3HuXrYDpAyt5mb0SzDCoIqg6/+haMtizdNSNLblCAvrsePP62QAmBsAD2oPsiAktEiNf/UOjCuBTDRqylCzV2Xjhps3tdK32RNkjnmBzHmmVfHZw7tO/tkxA0fUa0mh/Oeo/pQnBh0LEeauc4TnMZ30Uo42whGef9JYsVnDp7NRL0WJh4="
        static let legacy = "djEw+CEUYkkrlig/PqBWK46SXZTnbOVrC5FxBhg5AkJ3CXx6FQODGs5P9qtl7HrstfnLKBcAsK3M6K3QuYCNQwytdAlEvb5d2Hz/QpOpjFNfRaG+602u+cAiAyOs8EBqSo5F0a05+lPHPfhNhO/cZxGKB8EUiXanWCl/kVwf7Gw5NYb/mr3MqJ7vlD9Myo3HuXrYDpAyt5mb0SzDCoIqg6/+haMtizdNSNLblCAvrsePP62QAmBsAD2oPsiAktEiNf/UOjCuBTDRqylCzV2Xjhps3rQAtPRUt56Tj0HVncnDKraa29tDS7Fd4x116V/wHDrO+2HCBN/Qd44gJKh2Eq+mhpqn2doWwVbRkL86P/qiZZ8="
        static let tombstone = "djEw+CEUYkkrlig/PqBWK46SXZTnbOVrC5FxBhg5AkJ3CXx6FQODGs5P9qtl7HrstfnLKBcAsK3M6K3QuYCNQwytdAlEvb5d2Hz/QpOpjFNfRaG+602u+cAiAyOs8EBqSo5F0a05+lPHPfhNhO/cZxGKB8EUiXanWCl/kVwf7Gw5NYb/mr3MqJ7vlD9Myo3HuXrYDpAyt5mb0SzDCoIqg6/+haMtizdNSNLblCAvrsePP61vu0H039V5vb8SxmI2/vL6MZpUwqD5uMZ9msW/M2I64w=="
        static let cookieV24 = "djEwSX2hyiIGioCzucrKLiPJrQc2mpO5RD6G4SHi9qXa9urTiThcTclRPW5DN1gwM1pqtahdxAb+2WYwaxKTdviGFQ=="
        static let cookieLegacy = "djEw64uNJnBhMnm2TMmGNMqbLOljXQ5xTVLCGpQMZWN5jIg="
    }
}

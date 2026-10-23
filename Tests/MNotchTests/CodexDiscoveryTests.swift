import Foundation
import XCTest
@testable import MNotch

@MainActor
final class CodexDiscoveryTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/test-home")
    private let embeddedCLI = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

    func testFindsCurrentEmbeddedCLIWithMinimalGUIPath() {
        let binary = "/Applications/ChatGPT.app/\(embeddedCLI)"
        XCTAssertEqual(resolve(
            executables: [binary], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )?.path, binary)
    }

    func testFindsMovedOrRenamedRegisteredApplication() {
        let app = URL(fileURLWithPath: "/external/Tools/My Codex.app")
        let binary = app.appendingPathComponent(embeddedCLI).path
        XCTAssertEqual(resolve(executables: [binary], applicationURLs: [app])?.path, binary)
    }

    func testRetainsLegacyAndUserApplicationLayouts() {
        for binary in [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/test-home/Applications/Codex.app/\(embeddedCLI)",
            "/test-home/Applications/ChatGPT.app/\(embeddedCLI)",
            "/test-home/Applications/Codex.app/Contents/Resources/codex",
            "/test-home/Applications/ChatGPT.app/Contents/Resources/codex",
        ] {
            XCTAssertEqual(resolve(executables: [binary])?.path, binary)
        }
    }

    func testExplicitOverridesTakePrecedenceOverApplications() {
        let appBinary = "/Applications/ChatGPT.app/\(embeddedCLI)"
        let environment = [
            "MNOTCH_CODEX_BINARY": "/custom/mnotch-codex",
            "CODEX_BINARY": "/custom/codex",
        ]
        XCTAssertEqual(resolve(
            executables: [appBinary, "/custom/codex", "/custom/mnotch-codex"],
            environment: environment
        )?.path, "/custom/mnotch-codex")
        XCTAssertEqual(resolve(
            executables: [appBinary, "/custom/codex"], environment: environment
        )?.path, "/custom/codex")
        XCTAssertEqual(resolve(executables: [appBinary], environment: environment)?.path, appBinary)
    }

    func testRetainsCLIAndPathFallbacks() {
        for binary in [
            "/test-home/.local/bin/codex", "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex", "/usr/bin/codex", "/custom/bin/codex",
        ] {
            XCTAssertEqual(resolve(
                executables: [binary], environment: ["PATH": "/custom/bin"]
            )?.path, binary)
        }
    }

    func testMissingExecutableReturnsNil() {
        XCTAssertNil(resolve(executables: []))
    }

    private func resolve(
        executables: Set<String>,
        environment: [String: String] = [:],
        applicationURLs: [URL] = []
    ) -> URL? {
        CodexQuotaClient.findCodexBinary(
            environment: environment,
            homeDirectory: home,
            applicationURLs: applicationURLs,
            isExecutableFile: { executables.contains($0) }
        )
    }
}

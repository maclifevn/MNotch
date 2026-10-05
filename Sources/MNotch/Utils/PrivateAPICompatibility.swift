import Foundation

enum PrivateAPICompatibility {
    enum Integration: String, CaseIterable, Codable {
        case displayBrightness, keyboardBacklight, lockScreen
    }

    // No in-process private integration has completed the audit's hardware
    // acceptance matrix yet. Add an exact major.minor version only after the
    // manual scenarios in AUDIT.md pass. Symbols existing is not ABI proof.
    static let verifiedVersions: [Integration: Set<String>] = [:]

    static func permits(
        _ integration: Integration,
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        verified: [Integration: Set<String>] = verifiedVersions
    ) -> Bool {
        verified[integration]?.contains("\(version.majorVersion).\(version.minorVersion)") == true
    }

    static var unavailableReason: String {
        "Private macOS integration is disabled until this macOS version completes compatibility verification."
    }
}

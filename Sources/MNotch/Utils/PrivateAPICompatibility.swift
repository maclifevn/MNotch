import Foundation

enum PrivateAPICompatibility {
    enum Integration: String, CaseIterable, Codable {
        case displayBrightness, keyboardBacklight, lockScreen
    }

    // DisplayServices brightness is probed on the active built-in display at
    // runtime. A model/build allowlist would disable it on every other Mac or
    // OS update, even when the same get/set API works. The more invasive private
    // integrations still require explicit verification.
    static let verifiedVersions: [Integration: Set<String>] = [:]

    static func permits(
        _ integration: Integration,
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        verified: [Integration: Set<String>] = verifiedVersions
    ) -> Bool {
        // Permission to probe is not permission to consume brightness keys:
        // BrightnessService.available additionally requires a fresh, valid
        // hardware sample and is revoked on a failed write or stalled call.
        if integration == .displayBrightness { return version.majorVersion >= 15 }
        return verified[integration]?.contains("\(version.majorVersion).\(version.minorVersion)") == true
    }

    static var unavailableReason: String {
        "Private macOS integration is disabled until this macOS version completes compatibility verification."
    }
}

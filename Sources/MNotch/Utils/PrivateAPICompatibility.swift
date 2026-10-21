import Foundation
import Darwin

enum PrivateAPICompatibility {
    enum Integration: String, CaseIterable, Codable {
        case displayBrightness, keyboardBacklight, lockScreen
    }

    // Broad major.minor approvals remain empty. Brightness has a narrower,
    // explicitly verified host entry below; other private integrations stay off.
    static let verifiedVersions: [Integration: Set<String>] = [:]

    struct VerifiedHost: Hashable, Sendable {
        let version: String
        let build: String
        let model: String
    }

    // Hardware read/write and bounded worker tests are recorded in AUDIT.md.
    // A different OS patch/build or Mac requires its own verification.
    static let verifiedBrightnessHosts: Set<VerifiedHost> = [
        .init(version: "27.0.1", build: "26A434", model: "Mac17,3"),
    ]
    static let operatingSystemBuild = sysctlString("kern.osversion")
    static let hardwareModel = sysctlString("hw.model")

    static func permits(
        _ integration: Integration,
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        verified: [Integration: Set<String>] = verifiedVersions,
        build: String = operatingSystemBuild,
        model: String = hardwareModel
    ) -> Bool {
        if integration == .displayBrightness,
           verifiedBrightnessHosts.contains(.init(
               version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
               build: build, model: model
           )) { return true }
        return verified[integration]?.contains("\(version.majorVersion).\(version.minorVersion)") == true
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static var unavailableReason: String {
        "Private macOS integration is disabled until this macOS version completes compatibility verification."
    }
}

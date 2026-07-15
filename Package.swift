// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MNotch",
    platforms: [
        .macOS("15.0")
    ],
    targets: [
        .executableTarget(
            name: "MNotch",
            path: "Sources/MNotch"
        ),
        .testTarget(
            name: "MNotchTests",
            dependencies: ["MNotch"],
            path: "Tests/MNotchTests"
        ),
    ]
)

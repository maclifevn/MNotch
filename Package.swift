// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MNotch",
    platforms: [
        .macOS("15.0")
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        ),
    ],
    targets: [
        .executableTarget(
            name: "MNotch",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MNotch",
            linkerSettings: [
                // Scripts/build.sh assembles a conventional .app bundle and
                // embeds Sparkle under Contents/Frameworks.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "MNotchTests",
            dependencies: ["MNotch"],
            path: "Tests/MNotchTests"
        ),
    ]
)

// swift-tools-version: 6.1
import PackageDescription

// Native macOS app. Build the .app with scripts/build.sh (SwiftPM builds the
// binary, the script wraps it in a signed bundle).
let package = Package(
    name: "Grapefruit",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Grapefruit",
            path: "Sources/Grapefruit",
            swiftSettings: [
                // Swift 5 mode keeps AppKit callbacks free of strict-concurrency noise.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

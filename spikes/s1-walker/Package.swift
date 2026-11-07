// swift-tools-version: 6.4
import PackageDescription

// Spike S1: directory walker benchmark. Not shipped, never imported by the app.
let package = Package(
    name: "s1-walker",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "s1walker",
            path: "Sources/s1walker",
            swiftSettings: [.treatAllWarnings(as: .error)]
        )
    ],
    swiftLanguageModes: [.v6]
)

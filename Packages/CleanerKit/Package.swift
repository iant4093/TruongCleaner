// swift-tools-version: 6.4
import PackageDescription

/// Every target compiles in Swift 6 mode with warnings as errors.
let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "CleanerKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
        .library(name: "CleanerScanner", targets: ["CleanerScanner"]),
        .library(name: "CleanerActions", targets: ["CleanerActions"]),
    ],
    targets: [
        .target(
            name: "CleanerCore",
            path: "Sources/CleanerCore",
            swiftSettings: strictSettings
        ),
        .target(
            name: "CleanerScanner",
            dependencies: ["CleanerCore"],
            path: "Sources/CleanerScanner",
            swiftSettings: strictSettings
        ),
        .target(
            name: "CleanerActions",
            dependencies: ["CleanerCore", "CleanerScanner"],
            path: "Sources/CleanerActions",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "tcbench",
            dependencies: ["CleanerCore", "CleanerScanner"],
            path: "Sources/tcbench",
            swiftSettings: strictSettings
        ),
        // Test helpers only. Not a product; the app never links it.
        .target(
            name: "CleanerTestSupport",
            dependencies: ["CleanerCore"],
            path: "Tests/Fixtures",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "CleanerCoreTests",
            dependencies: ["CleanerCore", "CleanerTestSupport"],
            path: "Tests/CleanerCoreTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "CleanerScannerTests",
            dependencies: ["CleanerScanner", "CleanerTestSupport"],
            path: "Tests/CleanerScannerTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "CleanerActionsTests",
            dependencies: ["CleanerActions", "CleanerTestSupport"],
            path: "Tests/CleanerActionsTests",
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.4
import PackageDescription

// Spike S4: which storage numbers can a normal user process read on macOS?
// Read-only. Never imported by the app or CleanerKit.
let package = Package(
    name: "s4-volume",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "s4volume",
            path: "Sources/s4volume",
            swiftSettings: [
                .treatAllWarnings(as: .error),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

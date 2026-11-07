// swift-tools-version: 6.4
import PackageDescription

// Spike S2: which Full Disk Access probes work on macOS 27. Never imported by
// the app or the kit. All probes are read-only.
let package = Package(
    name: "S2FDA",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "S2FDA",
            swiftSettings: [.treatAllWarnings(as: .error)]
        )
    ],
    swiftLanguageModes: [.v6]
)

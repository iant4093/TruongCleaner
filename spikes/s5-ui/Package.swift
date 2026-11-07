// swift-tools-version: 6.4
import PackageDescription

// Spike S5: throwaway SwiftUI prototype. Static fake data only.
// Never imported by Packages/ or src/.
let package = Package(
    name: "S5UI",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "S5UI",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
            ]
        ),
    ]
)

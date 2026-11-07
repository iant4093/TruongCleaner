// swift-tools-version: 6.4
import PackageDescription

// Spike S3: Trash behavior. Throwaway; never imported by the app.
let package = Package(
    name: "s3trash",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "s3trash",
            path: "Sources/s3trash",
            swiftSettings: [.treatAllWarnings(as: .error)]
        )
    ],
    swiftLanguageModes: [.v6]
)

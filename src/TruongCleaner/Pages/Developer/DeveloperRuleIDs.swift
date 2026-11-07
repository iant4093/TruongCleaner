import CleanerCore

/// Which catalog rules each section of the Developer page shows (`docs/RULE_CATALOG.md` §4.6).
enum DeveloperRuleIDs {
    /// File rules in the Xcode section, in display order.
    static let xcode = [
        "dev.xcodeDerivedData",
        "dev.xcodeDeviceSupport",
        "dev.xcodePreviews",
        "dev.xcodeCaches",
        "dev.xcodeDocCache",
        "dev.xcodeArchives",
        "dev.xctestDevices",
    ]

    /// File rules in the Package managers section, in display order.
    static let packageManagers = [
        "dev.swiftpm",
        "dev.npm",
        "dev.yarn",
        "dev.bun",
        "dev.pip",
        "dev.uv",
        "dev.cargo",
        "dev.cocoapods",
        "dev.gradle",
        "dev.maven",
        "dev.androidCaches",
    ]

    /// File rules in the Simulators section.
    static let simulatorFiles = ["dev.simCaches"]

    /// Owner-command rules in the Package managers section, in display order.
    static let packageCommands = ["dev.homebrew", "dev.pnpm", "dev.go", "dev.goModules"]

    /// The Docker command rule.
    static let dockerCommand = "dev.dockerDangling"

    /// The Docker Info rule: the size of the disk image, never cleaned.
    static let dockerInfo = "dev.dockerImage"

    /// The simulator command rule behind "Delete Unavailable Simulators".
    static let simulatorCommand = "dev.simUnavailable"

    /// The rule behind deleting one simulator device.
    static let simulatorDevices = "dev.simDevices"

    /// The rule behind deleting one simulator runtime.
    static let simulatorRuntimes = "dev.simRuntimes"

    /// The rule that looks for build folders inside project folders.
    static let projects = "dev.projectArtifacts"

    /// Rules the page's main scan walks: file rules plus the Docker Info rule.
    static let scanned = Set(xcode + simulatorFiles + packageManagers + [dockerInfo])
}

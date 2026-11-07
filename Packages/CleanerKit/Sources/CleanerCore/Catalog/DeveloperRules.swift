import Foundation

/// Rules from `docs/RULE_CATALOG.md` §4.6 (Developer), in catalog order.
///
/// Owner-command rules (`dev.simUnavailable`, `dev.homebrew`, ...) have no roots: the owner's own
/// tool frees the space and nothing is walked. Each names its command by ID in
/// `CleanerActions.OwnerCommands.all`; `CatalogOwnerCommandTests` keeps the two in step.
enum DeveloperRules {
    /// Every rule in the Developer section.
    static let all: [Rule] = [
        xcodeDerivedData,
        xcodeDeviceSupport,
        xcodePreviews,
        xcodeCaches,
        xcodeArchives,
        xcodeDocCache,
        simUnavailable,
        simDevices,
        simRuntimes,
        simCaches,
        xctestDevices,
        swiftpm,
        homebrew,
        npm,
        yarn,
        pnpm,
        bun,
        pip,
        uv,
        cargo,
        goBuildCache,
        goModules,
        gradle,
        maven,
        cocoapods,
        androidCaches,
        dockerDangling,
        dockerImage,
        projectArtifacts,
    ]

    // MARK: - Owners

    /// Xcode and command-line builds share DerivedData, previews and caches.
    private static let xcodeOwners: [OwnerSpec] = [.bundleID("com.apple.dt.Xcode"), .processName("xcodebuild")]

    /// "No simulator booted" cannot be asked of the file system. Simulator.app and the `launchd_sim`
    /// process that every booted device runs stand in for it; either one blocks the rule.
    private static let simulatorOwners: [OwnerSpec] = [
        .bundleID("com.apple.iphonesimulator"), .processName("launchd_sim"),
    ]

    private static func xcode(_ components: [String]) -> RootSpec {
        .home(["Library", "Developer", "Xcode"] + components)
    }

    // MARK: - Xcode

    /// Each child of `DerivedData`.
    static let xcodeDerivedData = Rule(
        id: "dev.xcodeDerivedData",
        category: .developer,
        tier: .safe,
        roots: [xcode(["DerivedData"])],
        match: .children,
        guards: Guards(owners: xcodeOwners),
        access: .user,
        action: .trash,
        title: "Xcode build products",
        explain: "Build products; Xcode rebuilds them."
    )

    /// Each child of the five `<platform> DeviceSupport` folders. The two newest of each folder stay.
    static let xcodeDeviceSupport = Rule(
        id: "dev.xcodeDeviceSupport",
        category: .developer,
        tier: .safe,
        roots: ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].map { xcode(["\($0) DeviceSupport"]) },
        match: .children,
        guards: Guards(keepNewest: 2),
        access: .user,
        action: .trash,
        title: "Xcode device support files",
        explain: "Debug symbols copied from devices. Xcode copies them again when you connect the device."
    )

    /// Each child of `UserData/Previews`.
    static let xcodePreviews = Rule(
        id: "dev.xcodePreviews",
        category: .developer,
        tier: .safe,
        roots: [xcode(["UserData", "Previews"])],
        match: .children,
        guards: Guards(owners: xcodeOwners),
        access: .user,
        action: .trash,
        title: "SwiftUI preview builds",
        explain: "SwiftUI preview builds."
    )

    /// Each child of Xcode's own folder in `~/Library/Caches`.
    static let xcodeCaches = Rule(
        id: "dev.xcodeCaches",
        category: .developer,
        tier: .safe,
        roots: [.home(["Library", "Caches", "com.apple.dt.Xcode"])],
        match: .children,
        guards: Guards(owners: xcodeOwners),
        access: .user,
        action: .trash,
        title: "Xcode cache",
        explain: "Xcode's own cache."
    )

    /// `.xcarchive` bundles inside the date folders of `Archives`. Never selected by default.
    static let xcodeArchives = Rule(
        id: "dev.xcodeArchives",
        category: .developer,
        tier: .review,
        roots: [xcode(["Archives"])],
        match: .glob("*/*.xcarchive"),
        depth: 2,
        access: .user,
        action: .trash,
        title: "Xcode archives",
        explain: "App builds you exported; they hold crash symbols for shipped versions."
    )

    /// Each child of `DocumentationCache`. The newest stays.
    static let xcodeDocCache = Rule(
        id: "dev.xcodeDocCache",
        category: .developer,
        tier: .safe,
        roots: [xcode(["DocumentationCache"])],
        match: .children,
        guards: Guards(keepNewest: 1),
        access: .user,
        action: .trash,
        title: "Xcode documentation cache",
        explain: "Downloaded documentation."
    )

    // MARK: - Simulators

    private static let xcrun = URL(filePath: "/usr/bin/xcrun")

    /// `xcrun simctl delete unavailable`. Mirrors `OwnerCommands.all["simctl.deleteUnavailable"]`.
    private static let deleteUnavailable = OwnerCommandSpec(
        id: "simctl.deleteUnavailable",
        executable: xcrun,
        arguments: ["simctl", "delete", "unavailable"],
        timeout: .seconds(120)
    )

    /// `xcrun simctl delete <UDID>`. The UDID is added by `OwnerCommandRunner.deleteSimulator(udid:)`;
    /// the command is not in `OwnerCommands.all`.
    private static let deleteDevice = OwnerCommandSpec(
        id: "simctl.deleteDevice",
        executable: xcrun,
        arguments: ["simctl", "delete"],
        timeout: .seconds(120)
    )

    /// `xcrun simctl runtime delete <identifier>`. The identifier is added by
    /// `OwnerCommandRunner.deleteSimulatorRuntime(identifier:)`; the command is not in `OwnerCommands.all`.
    private static let deleteRuntime = OwnerCommandSpec(
        id: "simctl.deleteRuntime",
        executable: xcrun,
        arguments: ["simctl", "runtime", "delete"],
        timeout: .seconds(300)
    )

    /// Simulators for runtimes that are no longer installed.
    static let simUnavailable = Rule(
        id: "dev.simUnavailable",
        category: .developer,
        tier: .safe,
        roots: [],
        match: .ownerCommand(deleteUnavailable),
        access: .user,
        action: .ownerCommand(deleteUnavailable),
        title: "Unavailable simulators",
        explain: "Simulators for runtimes you no longer have."
    )

    /// One simulator device and its apps and data. The list comes from `Simulators`, not from a walk;
    /// the data lives in `~/Library/Developer/CoreSimulator/Devices/<UDID>`.
    static let simDevices = Rule(
        id: "dev.simDevices",
        category: .developer,
        tier: .review,
        roots: [],
        match: .ownerCommand(deleteDevice),
        access: .user,
        action: .ownerCommand(deleteDevice),
        title: "Simulators",
        explain: "One simulator and its apps and data."
    )

    /// One simulator OS. Removed with `simctl`, never with `rm`.
    static let simRuntimes = Rule(
        id: "dev.simRuntimes",
        category: .developer,
        tier: .review,
        roots: [],
        match: .ownerCommand(deleteRuntime),
        access: .user,
        action: .ownerCommand(deleteRuntime),
        title: "Simulator runtimes",
        explain: "A simulator OS; Xcode can download it again."
    )

    /// Each child of `CoreSimulator/Caches`.
    static let simCaches = Rule(
        id: "dev.simCaches",
        category: .developer,
        tier: .safe,
        roots: [.home(["Library", "Developer", "CoreSimulator", "Caches"])],
        match: .children,
        guards: Guards(owners: simulatorOwners),
        access: .user,
        action: .trash,
        title: "Simulator caches",
        explain: "Simulator caches."
    )

    /// Each child of `XCTestDevices`. Test clones are simulators too, so the simulator owners apply.
    static let xctestDevices = Rule(
        id: "dev.xctestDevices",
        category: .developer,
        tier: .safe,
        roots: [.home(["Library", "Developer", "XCTestDevices"])],
        match: .children,
        guards: Guards(owners: xcodeOwners + simulatorOwners),
        access: .user,
        action: .trash,
        title: "Test simulator clones",
        explain: "Leftover test clones."
    )

    // MARK: - Package managers and build tools

    /// Each child of the two Swift package caches.
    static let swiftpm = Rule(
        id: "dev.swiftpm",
        category: .developer,
        tier: .safe,
        roots: [
            .home(["Library", "Caches", "org.swift.swiftpm"]),
            .home([".cache", "swift-package-manager"]),
        ],
        match: .children,
        guards: Guards(owners: [.processName("swift")]),
        access: .user,
        action: .trash,
        title: "Swift package cache",
        explain: "Downloaded Swift packages."
    )

    /// `brew cleanup --prune=30`. Mirrors `OwnerCommands.all["brew.cleanup"]` (300 s; the catalog says 120 s).
    private static let brewCleanup = OwnerCommandSpec(
        id: "brew.cleanup",
        executable: URL(filePath: "/opt/homebrew/bin/brew"),
        arguments: ["cleanup", "--prune=30"],
        timeout: .seconds(300)
    )

    /// Old Homebrew downloads and versions, cleaned by Homebrew itself.
    static let homebrew = Rule(
        id: "dev.homebrew",
        category: .developer,
        tier: .safe,
        roots: [],
        match: .ownerCommand(brewCleanup),
        access: .user,
        action: .ownerCommand(brewCleanup),
        title: "Homebrew leftovers",
        explain: "Old Homebrew downloads and versions."
    )

    /// Each child of npm's download cache. `~/.npm/_npx` is a sibling of `_cacache`, so it is not in the root.
    static let npm = Rule(
        id: "dev.npm",
        category: .developer,
        tier: .safe,
        roots: [.home([".npm", "_cacache"])],
        match: .children,
        guards: Guards(owners: [.processName("npm")]),
        access: .user,
        action: .trash,
        title: "npm cache",
        explain: "npm's download cache."
    )

    /// Each child of Yarn's download cache.
    static let yarn = Rule(
        id: "dev.yarn",
        category: .developer,
        tier: .safe,
        roots: [.home(["Library", "Caches", "Yarn"])],
        match: .children,
        guards: Guards(owners: [.processName("yarn")]),
        access: .user,
        action: .trash,
        title: "Yarn cache",
        explain: "Yarn's download cache."
    )

    /// `pnpm store prune`. Mirrors `OwnerCommands.all["pnpm.storePrune"]`.
    private static let pnpmStorePrune = OwnerCommandSpec(
        id: "pnpm.storePrune",
        executable: URL(filePath: "/opt/homebrew/bin/pnpm"),
        arguments: ["store", "prune"],
        timeout: .seconds(300)
    )

    /// Unused packages in pnpm's store, removed by pnpm itself.
    static let pnpm = Rule(
        id: "dev.pnpm",
        category: .developer,
        tier: .safe,
        roots: [],
        match: .ownerCommand(pnpmStorePrune),
        access: .user,
        action: .ownerCommand(pnpmStorePrune),
        title: "pnpm store",
        explain: "Unused packages in pnpm's store."
    )

    /// Each child of Bun's download cache.
    static let bun = Rule(
        id: "dev.bun",
        category: .developer,
        tier: .safe,
        roots: [.home([".bun", "install", "cache"])],
        match: .children,
        guards: Guards(owners: [.processName("bun")]),
        access: .user,
        action: .trash,
        title: "Bun cache",
        explain: "Bun's download cache."
    )

    /// Each child of the two pip cache folders.
    static let pip = Rule(
        id: "dev.pip",
        category: .developer,
        tier: .safe,
        roots: [
            .home(["Library", "Caches", "pip"]),
            .home([".cache", "pip"]),
        ],
        match: .children,
        access: .user,
        action: .trash,
        title: "pip cache",
        explain: "pip's download cache."
    )

    /// Each child of uv's cache.
    static let uv = Rule(
        id: "dev.uv",
        category: .developer,
        tier: .safe,
        roots: [.home([".cache", "uv"])],
        match: .children,
        guards: Guards(owners: [.processName("uv")]),
        access: .user,
        action: .trash,
        title: "uv cache",
        explain: "uv's cache."
    )

    /// Each child of `registry/cache`. Unpacked sources, the index and git checkouts are protected
    /// and are not in the root.
    static let cargo = Rule(
        id: "dev.cargo",
        category: .developer,
        tier: .safe,
        roots: [.home([".cargo", "registry", "cache"])],
        match: .children,
        guards: Guards(owners: [.processName("cargo")]),
        access: .user,
        action: .trash,
        title: "Cargo crate downloads",
        explain: "Downloaded crate archives (sources stay)."
    )

    private static let goPath = URL(filePath: "/opt/homebrew/bin/go")

    /// `go clean -cache`. Mirrors `OwnerCommands.all["go.cleanCache"]`.
    private static let goCleanCache = OwnerCommandSpec(
        id: "go.cleanCache",
        executable: goPath,
        arguments: ["clean", "-cache"],
        timeout: .seconds(300)
    )

    /// `go clean -modcache`. Mirrors `OwnerCommands.all["go.cleanModcache"]`.
    private static let goCleanModcache = OwnerCommandSpec(
        id: "go.cleanModcache",
        executable: goPath,
        arguments: ["clean", "-modcache"],
        timeout: .seconds(300)
    )

    /// Go's build cache, cleaned by `go`. The rule ID is `dev.go` as in the catalog.
    static let goBuildCache = Rule(
        id: "dev.go",
        category: .developer,
        tier: .safe,
        roots: [],
        match: .ownerCommand(goCleanCache),
        access: .user,
        action: .ownerCommand(goCleanCache),
        title: "Go build cache",
        explain: "Go build cache."
    )

    /// Downloaded Go modules, removed by `go`.
    static let goModules = Rule(
        id: "dev.goModules",
        category: .developer,
        tier: .review,
        roots: [],
        match: .ownerCommand(goCleanModcache),
        access: .user,
        action: .ownerCommand(goCleanModcache),
        title: "Go modules",
        explain: "Downloaded Go modules."
    )

    /// Each child of Gradle's caches and wrapper distributions.
    ///
    /// The Gradle daemon runs as `java`, so `gradle` as a process name catches the command-line
    /// client only; a running daemon is not detected.
    static let gradle = Rule(
        id: "dev.gradle",
        category: .developer,
        tier: .review,
        roots: [
            .home([".gradle", "caches"]),
            .home([".gradle", "wrapper", "dists"]),
        ],
        match: .children,
        guards: Guards(owners: [.processName("gradle")]),
        access: .user,
        action: .trash,
        title: "Gradle downloads",
        explain: "Gradle downloads; slow to rebuild."
    )

    /// Each child of the local Maven repository.
    static let maven = Rule(
        id: "dev.maven",
        category: .developer,
        tier: .review,
        roots: [.home([".m2", "repository"])],
        match: .children,
        access: .user,
        action: .trash,
        title: "Maven downloads",
        explain: "Maven downloads; slow to rebuild."
    )

    /// Each child of the CocoaPods cache.
    static let cocoapods = Rule(
        id: "dev.cocoapods",
        category: .developer,
        tier: .safe,
        roots: [.home(["Library", "Caches", "CocoaPods"])],
        match: .children,
        guards: Guards(owners: [.processName("pod")]),
        access: .user,
        action: .trash,
        title: "CocoaPods cache",
        explain: "CocoaPods cache."
    )

    /// Each child of the Android build caches and of Android Studio's cache folders.
    static let androidCaches = Rule(
        id: "dev.androidCaches",
        category: .developer,
        tier: .safe,
        roots: [
            .home([".android", "cache"]),
            .home([".android", "build-cache"]),
            .home(["Library", "Caches", "Google", "AndroidStudio*"]),
        ],
        match: .children,
        guards: Guards(owners: [.bundleID("com.google.android.studio")]),
        access: .user,
        action: .trash,
        title: "Android build caches",
        explain: "Android build caches."
    )

    // MARK: - Docker

    private static let docker = URL(filePath: "/usr/local/bin/docker")

    /// `docker image prune -f`. Mirrors `OwnerCommands.all["docker.imagePrune"]`.
    private static let dockerImagePrune = OwnerCommandSpec(
        id: "docker.imagePrune",
        executable: docker,
        arguments: ["image", "prune", "-f"],
        timeout: .seconds(300),
        followUps: [dockerBuilderPrune]
    )

    /// `docker builder prune -f --filter until=168h`. Mirrors `OwnerCommands.all["docker.builderPrune"]`.
    private static let dockerBuilderPrune = OwnerCommandSpec(
        id: "docker.builderPrune",
        executable: docker,
        arguments: ["builder", "prune", "-f", "--filter", "until=168h"],
        timeout: .seconds(300)
    )

    /// Unused image layers, then week-old build cache. Volumes are never pruned.
    /// Two commands, so the first one carries the second as a follow-up.
    static let dockerDangling = Rule(
        id: "dev.dockerDangling",
        category: .developer,
        tier: .safe,
        roots: [],
        match: .ownerCommand(dockerImagePrune),
        access: .user,
        action: .ownerCommand(dockerImagePrune),
        title: "Docker unused images and build cache",
        explain: "Unused image layers and old build cache. Volumes are never touched."
    )

    /// Info only: Docker's disk file never shrinks by itself.
    ///
    /// The catalog names `Docker.raw`. A root must be a folder, so this measures the `data`
    /// folder that holds it.
    static let dockerImage = Rule(
        id: "dev.dockerImage",
        category: .developer,
        tier: .info,
        roots: [.home(["Library", "Containers", "com.docker.docker", "Data", "vms", "0", "data"])],
        match: .measureOnly,
        access: .fda,
        action: .none,
        title: "Docker disk image",
        explain: """
            Docker's disk file does not shrink by itself. \
            To reduce it, open Docker Desktop, then Settings > Resources.
            """
    )

    // MARK: - Project folders

    /// Build output inside the project folders the user chose, such as `~/Code`.
    ///
    /// - The pattern needs one folder between the chosen folder and the artifact, so an artifact
    ///   directly in the chosen folder is never offered.
    /// - `target` counts only beside `Cargo.toml`, `build` only beside a build file.
    /// - A match inside another match (`node_modules/x/node_modules`) is part of the outer one.
    /// - An artifact that holds a `.git` entry, or lies inside a `.git` folder, is kept. The catalog
    ///   also says "skip if git-tracked", which needs `git`; this guard is the part that can be checked
    ///   without it.
    /// - Folders the protected list covers (`~/Library/CloudStorage`, `~/Library/Mobile Documents`)
    ///   never produce items.
    static let projectArtifacts = Rule(
        id: "dev.projectArtifacts",
        category: .developer,
        tier: .review,
        roots: [RootSpec(base: .userChosen, components: [])],
        match: .glob(
            "*/**/{node_modules,.build,DerivedData,target,build,.next/cache,.venv,__pycache__,Pods,.gradle,.dart_tool}"
        ),
        depth: 6,
        guards: Guards(
            minAge: .days(30),
            excludeNames: [".git"],
            requiresSiblingByName: [
                "target": ["Cargo.toml"],
                "build": ["build.gradle", "build.gradle.kts", "CMakeLists.txt", "package.json", "Makefile"],
            ],
            skipIfContains: [".git"]
        ),
        access: .user,
        action: .trash,
        title: "Project build folders",
        explain: "Build output of projects you have not touched in a month."
    )
}

/// Rules from `docs/RULE_CATALOG.md` §4.1 (Caches), in catalog order.
enum CachesRules {
    /// Every rule in the Caches section.
    static let all: [Rule] = [
        userCaches,
        userContainerCaches,
        userGroupContainerCaches,
        userSavedState,
        userDarwinCache,
        userDarwinTemp,
        userGPUCaches,
        userQuickLook,
        systemLibraryCaches,
    ]

    /// Each child of `~/Library/Caches`. Browser folders are left to the browser rules.
    ///
    /// `BraveSoftware`, `Chromium`, `Microsoft Edge` and `Vivaldi` are excluded as well as the
    /// catalog's `Google` and `Firefox`: those folders are not bundle IDs, so the owner guard
    /// cannot tell which browser to check. Excluding more is the safe direction.
    static let userCaches = Rule(
        id: "user.caches",
        category: .caches,
        tier: .safe,
        roots: [.home(["Library", "Caches"])],
        match: .children,
        guards: Guards(
            owners: [.childNameAsBundleID(stripSuffix: nil)],
            excludeNames: ["Google", "Firefox", "BraveSoftware", "Chromium", "Microsoft Edge", "Vivaldi"]
        ),
        access: .user,
        action: .trash,
        title: "App caches",
        explain: "Apps keep temporary copies here and rebuild them."
    )

    /// Apple's own containers and shared groups are never cleaned. The patterns are matched
    /// against the folder name that the `*` of the root stands for.
    static let appleContainerNames = ["com.apple.*", "group.com.apple.*", "*.com.apple.*", "systemgroup.*"]

    /// Each child of the `Data/Library/Caches` folder of a third-party App Store app's container.
    ///
    /// Containers whose name matches `appleContainerNames` are left out. The container's name
    /// is the app's bundle ID, so the app must be closed (`rootSegmentAsBundleID`, index 2).
    static let userContainerCaches = Rule(
        id: "user.containerCaches",
        category: .caches,
        tier: .safe,
        roots: [.home(["Library", "Containers", "*", "Data", "Library", "Caches"])],
        match: .children,
        guards: Guards(
            owners: [.rootSegmentAsBundleID(index: 2)],
            excludeRootSegments: appleContainerNames
        ),
        access: .fda,
        action: .trash,
        title: "App Store app caches",
        explain: "Caches of App Store apps."
    )

    /// Each child of the `Library/Caches` folder of a third-party app group.
    ///
    /// Tier is Review, not the catalog's Safe: a group container is shared by several apps and
    /// its name (`group.<team>.<name>`) does not say which app to check, so no owner check is
    /// possible. Review rows are never selected by default.
    static let userGroupContainerCaches = Rule(
        id: "user.groupContainerCaches",
        category: .caches,
        tier: .review,
        roots: [.home(["Library", "Group Containers", "*", "Library", "Caches"])],
        match: .children,
        guards: Guards(excludeRootSegments: appleContainerNames),
        access: .fda,
        action: .trash,
        title: "Shared app caches",
        explain: "Caches shared by an app family."
    )

    /// Each child of `~/Library/Saved Application State`. The folder names end in
    /// `.savedState`; the gate must strip that suffix before it reads the name as a bundle ID.
    static let userSavedState = Rule(
        id: "user.savedState",
        category: .caches,
        tier: .safe,
        roots: [.home(["Library", "Saved Application State"])],
        match: .children,
        guards: Guards(owners: [.childNameAsBundleID(stripSuffix: ".savedState")]),
        access: .user,
        action: .trash,
        title: "Saved window state",
        explain: "Window positions to restore after restart."
    )

    /// Each child of `DARWIN_USER_CACHE_DIR` older than 7 days.
    static let userDarwinCache = Rule(
        id: "user.darwinCache",
        category: .caches,
        tier: .review,
        roots: [.darwinCache()],
        match: .children,
        guards: Guards(minAge: .days(7), owners: [.childNameAsBundleID(stripSuffix: nil)]),
        access: .user,
        action: .trash,
        title: "System caches for your account",
        explain: "Per-user system caches in /private/var/folders."
    )

    /// Each child of `DARWIN_USER_TEMP_DIR` older than 3 days.
    static let userDarwinTemp = Rule(
        id: "user.darwinTemp",
        category: .caches,
        tier: .review,
        roots: [.darwinTemp()],
        match: .children,
        guards: Guards(minAge: .days(3)),
        access: .user,
        action: .trash,
        title: "Temporary files",
        explain: "Temporary files apps forgot to delete."
    )

    /// Each child of the Metal and GPU archiver cache folders, older than 1 day.
    static let userGPUCaches = Rule(
        id: "user.gpuCaches",
        category: .caches,
        tier: .safe,
        roots: ["com.apple.metal", "com.apple.metalfe", "com.apple.gpuarchiver"].map {
            .darwinCache(["*", $0])
        },
        match: .children,
        guards: Guards(minAge: .days(1)),
        access: .user,
        action: .trash,
        title: "Graphics shader caches",
        explain: "Compiled graphics shaders; rebuilt on demand."
    )

    /// Each child of the Quick Look thumbnail cache. The folder itself stays.
    static let userQuickLook = Rule(
        id: "user.quickLook",
        category: .caches,
        tier: .safe,
        roots: [.home(["Library", "Caches", "com.apple.QuickLook.thumbnailcache"])],
        match: .children,
        access: .user,
        action: .trash,
        title: "Quick Look thumbnails",
        explain: "Finder preview thumbnails."
    )

    /// Info only: `/Library/Caches` needs root to change.
    static let systemLibraryCaches = Rule(
        id: "system.libraryCaches",
        category: .caches,
        tier: .info,
        roots: [.absolute(["Library", "Caches"])],
        match: .measureOnly,
        access: .root,
        action: .none,
        title: "Shared system caches",
        explain: "Shared caches owned by the system or other users. Only macOS can clean them."
    )
}

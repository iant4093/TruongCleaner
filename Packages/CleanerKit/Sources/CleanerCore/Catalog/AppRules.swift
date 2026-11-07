/// Rules from `docs/RULE_CATALOG.md` §4.5 (App caches, third-party), in catalog order.
///
/// Only the folders named in the catalog are roots. As in `BrowserRules`, `Guards.owners` is
/// one list per rule, so the gate skips the rule's items while any listed app runs.
enum AppRules {
    /// Every rule in the App caches section.
    static let all: [Rule] = [
        appsElectronCaches,
        appsSpotifyMedia,
        appsAdobeMediaCache,
        appsSteam,
        appsCloudClientCaches,
    ]

    /// One Electron-style app: its folder below `~/Library/Application Support` and bundle IDs.
    struct ElectronApp {
        /// Path below `~/Library/Application Support`.
        let support: [String]
        /// Bundle identifiers of the app.
        let bundleIDs: [String]
    }

    /// The apps named in the catalog. Discord and Visual Studio Code bundle IDs were read from
    /// `/Applications/*/Contents/Info.plist`; the others are the vendors' published IDs.
    static let electronApps: [ElectronApp] = [
        ElectronApp(support: ["Slack"], bundleIDs: ["com.tinyspeck.slackmacgap"]),
        ElectronApp(support: ["discord"], bundleIDs: ["com.hnc.Discord"]),
        ElectronApp(support: ["Microsoft", "Teams"], bundleIDs: ["com.microsoft.teams", "com.microsoft.teams2"]),
        ElectronApp(support: ["zoom.us"], bundleIDs: ["us.zoom.xos"]),
        ElectronApp(support: ["Spotify"], bundleIDs: ["com.spotify.client"]),
        ElectronApp(support: ["Notion"], bundleIDs: ["notion.id"]),
        ElectronApp(support: ["obsidian"], bundleIDs: ["md.obsidian"]),
        ElectronApp(support: ["Figma"], bundleIDs: ["com.figma.Desktop"]),
        ElectronApp(support: ["Code"], bundleIDs: ["com.microsoft.VSCode"]),
        ElectronApp(support: ["Cursor"], bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        ElectronApp(support: ["Postman"], bundleIDs: ["com.postmanlabs.mac"]),
        ElectronApp(support: ["Signal"], bundleIDs: ["org.whispersystems.signal-desktop"]),
        ElectronApp(support: ["WhatsApp"], bundleIDs: ["net.whatsapp.WhatsApp"]),
    ]

    /// Folders inside an Electron app's support folder that the catalog allows.
    static let electronCacheFolders: [[String]] = [
        ["Cache"], ["Code Cache"], ["GPUCache"], ["DawnCache"], ["GrShaderCache"], ["CachedData"],
        ["Crashpad", "completed"], ["logs"],
    ]

    /// Cache and log folders of chat and editor apps. Messages and settings are not in any root.
    /// Access is `.fda` because the support folders are protected on this Mac (checked with Discord).
    static let appsElectronCaches = Rule(
        id: "apps.electronCaches",
        category: .apps,
        tier: .safe,
        roots: electronApps.flatMap { app in
            electronCacheFolders.map { RootSpec.home(["Library", "Application Support"] + app.support + $0) }
        },
        match: .children,
        guards: Guards(owners: electronApps.flatMap { $0.bundleIDs.map { OwnerSpec.bundleID($0) } }),
        access: .fda,
        action: .trash,
        title: "Chat and editor app caches",
        explain: "Chat and editor app caches. Messages and settings stay."
    )

    /// Spotify's streaming cache. Offline downloads are not in `Data`.
    static let appsSpotifyMedia = Rule(
        id: "apps.spotifyMedia",
        category: .apps,
        tier: .safe,
        roots: [.home(["Library", "Caches", "com.spotify.client", "Data"])],
        match: .children,
        guards: Guards(owners: [.bundleID("com.spotify.client")]),
        access: .user,
        action: .trash,
        title: "Spotify song cache",
        explain: "Downloaded song cache (not offline downloads)."
    )

    /// Adobe media cache folders. The catalog names no owner. Premiere's process names carry
    /// the year (for example `Adobe Premiere Pro 2025`), so these exact names may never match
    /// a running app; see the report.
    static let appsAdobeMediaCache = Rule(
        id: "apps.adobeMediaCache",
        category: .apps,
        tier: .review,
        roots: [
            .home(["Library", "Application Support", "Adobe", "Common", "Media Cache Files"]),
            .home(["Library", "Application Support", "Adobe", "Common", "Media Cache"]),
        ],
        match: .children,
        guards: Guards(owners: [
            .processName("Adobe Premiere Pro"),
            .processName("Adobe After Effects"),
            .processName("Adobe Media Encoder"),
            .processName("Adobe Audition"),
        ]),
        access: .user,
        action: .trash,
        title: "Adobe media cache",
        explain: "Video preview files; Premiere rebuilds them slowly."
    )

    /// Steam's cache folders. Installed games (`steamapps`) are not in any root.
    static let appsSteam = Rule(
        id: "apps.steam",
        category: .apps,
        tier: .safe,
        roots: ["appcache", "depotcache", "htmlcache", "shadercache", "logs"].map {
            .home(["Library", "Application Support", "Steam", $0])
        },
        match: .children,
        guards: Guards(owners: [.bundleID("com.valvesoftware.steam"), .processName("steam_osx")]),
        access: .user,
        action: .trash,
        title: "Steam caches",
        explain: "Steam caches. Games stay."
    )

    /// Cache folders of Dropbox, Google Drive and OneDrive clients. Synced files are elsewhere.
    static let appsCloudClientCaches = Rule(
        id: "apps.cloudClientCaches",
        category: .apps,
        tier: .safe,
        roots: ["com.dropbox.*", "com.google.GoogleDrive", "com.microsoft.OneDrive"].map {
            .home(["Library", "Caches", $0])
        },
        match: .children,
        guards: Guards(owners: [
            .bundleID("com.getdropbox.dropbox"),
            .bundleID("com.google.drivefs"),
            .bundleID("com.google.GoogleDrive"),
            .bundleID("com.microsoft.OneDrive"),
        ]),
        access: .user,
        action: .trash,
        title: "Sync client caches",
        explain: "Sync client caches; client must be quit. Synced files stay."
    )
}

/// Rules from `docs/RULE_CATALOG.md` §4.4 (Browsers), in catalog order.
///
/// `browser.chromium` puts each browser's bundle ID on that browser's own roots
/// (`RootSpec.owners`), so a running Chrome blocks only Chrome's caches.
enum BrowserRules {
    /// Every rule in the Browsers section.
    static let all: [Rule] = [
        browserSafari,
        browserChromium,
        browserChromiumModels,
        browserFirefox,
    ]

    /// One Chromium-family browser: where it keeps caches, profiles and its bundle ID.
    struct ChromiumBrowser {
        /// Path below `~/Library/Caches`.
        let caches: [String]
        /// Path below `~/Library/Application Support` that holds the profile folders.
        let support: [String]
        /// Bundle identifier, for the "browser must be closed" guard.
        let bundleID: String
    }

    /// The browsers named in the catalog. Chrome, Chromium, Brave, Edge and Vivaldi use the
    /// vendors' documented folders. Arc, Opera, Orion, Dia and Comet are best-known paths:
    /// a folder that does not exist matches nothing.
    static let chromiumBrowsers: [ChromiumBrowser] = [
        ChromiumBrowser(
            caches: ["Google", "Chrome"], support: ["Google", "Chrome"], bundleID: "com.google.Chrome"
        ),
        ChromiumBrowser(
            caches: ["Chromium"], support: ["Chromium"], bundleID: "org.chromium.Chromium"
        ),
        ChromiumBrowser(
            caches: ["BraveSoftware", "Brave-Browser"],
            support: ["BraveSoftware", "Brave-Browser"],
            bundleID: "com.brave.Browser"
        ),
        ChromiumBrowser(
            caches: ["Microsoft Edge"], support: ["Microsoft Edge"], bundleID: "com.microsoft.edgemac"
        ),
        ChromiumBrowser(
            caches: ["company.thebrowser.Browser"],
            support: ["Arc", "User Data"],
            bundleID: "company.thebrowser.Browser"
        ),
        ChromiumBrowser(
            caches: ["Vivaldi"], support: ["Vivaldi"], bundleID: "com.vivaldi.Vivaldi"
        ),
        ChromiumBrowser(
            caches: ["com.operasoftware.Opera"],
            support: ["com.operasoftware.Opera"],
            bundleID: "com.operasoftware.Opera"
        ),
        ChromiumBrowser(
            caches: ["com.kagi.kagimacOS"], support: ["Orion"], bundleID: "com.kagi.kagimacOS"
        ),
        ChromiumBrowser(
            caches: ["company.thebrowser.dia"],
            support: ["Dia", "User Data"],
            bundleID: "company.thebrowser.dia"
        ),
        ChromiumBrowser(
            caches: ["ai.perplexity.comet"], support: ["Comet"], bundleID: "ai.perplexity.comet"
        ),
    ]

    /// Cache folders inside each profile (`Default`, `Profile 1`, ...).
    static let profileCacheFolders = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "GrShaderCache", "GraphiteDawnCache",
    ]

    /// Cache folders directly inside a browser's support folder.
    static let browserLevelCacheFolders: [[String]] = [
        ["ShaderCache"], ["GrShaderCache"], ["component_crx_cache"], ["Crashpad", "completed"],
    ]

    /// Safari's web cache, in both the classic and the sandbox container location.
    static let browserSafari = Rule(
        id: "browser.safari",
        category: .browsers,
        tier: .safe,
        roots: [
            .home(["Library", "Caches", "com.apple.Safari"]),
            .home(["Library", "Containers", "com.apple.Safari", "Data", "Library", "Caches"]),
        ],
        match: .children,
        guards: Guards(owners: [.bundleID("com.apple.Safari")]),
        access: .fda,
        action: .trash,
        title: "Safari cache",
        explain: "Safari's web cache."
    )

    /// Cache folders of the Chromium family. Profiles, cookies, history and extensions are not
    /// in any root. Access is `.fda` because the support folders are protected on this Mac
    /// (checked with Chrome and Discord); the cache folders may need less.
    static let browserChromium = Rule(
        id: "browser.chromium",
        category: .browsers,
        tier: .safe,
        roots: chromiumBrowsers.flatMap { browser -> [RootSpec] in
            let support = ["Library", "Application Support"] + browser.support
            let owners = [OwnerSpec.bundleID(browser.bundleID)]
            return [.home(["Library", "Caches"] + browser.caches, owners: owners)]
                + profileCacheFolders.map { RootSpec.home(support + ["*", $0], owners: owners) }
                + browserLevelCacheFolders.map { RootSpec.home(support + $0, owners: owners) }
        },
        match: .children,
        access: .fda,
        action: .trash,
        title: "Chromium browser caches",
        explain: "Web and graphics caches. Sign-ins and tabs stay."
    )

    /// Chrome's downloaded on-device AI model. Chrome only, as in the catalog.
    static let browserChromiumModels = Rule(
        id: "browser.chromiumModels",
        category: .browsers,
        tier: .review,
        roots: ["OptGuideOnDeviceModel", "optimization_guide_model_store"].map {
            .home(["Library", "Application Support", "Google", "Chrome", $0])
        },
        match: .children,
        guards: Guards(owners: [.bundleID("com.google.Chrome")]),
        access: .fda,
        action: .trash,
        title: "Chrome on-device AI model",
        explain: "On-device AI model; Chrome downloads it again."
    )

    /// Firefox's cache folders. Profile folders are never roots or matches.
    static let browserFirefox = Rule(
        id: "browser.firefox",
        category: .browsers,
        tier: .safe,
        roots: [
            .home(["Library", "Caches", "Firefox"]),
            .home(["Library", "Application Support", "Firefox", "Profiles", "*", "cache2"]),
        ],
        match: .children,
        guards: Guards(owners: [.bundleID("org.mozilla.firefox")]),
        access: .fda,
        action: .trash,
        title: "Firefox cache",
        explain: "Firefox web cache. Profiles stay."
    )
}

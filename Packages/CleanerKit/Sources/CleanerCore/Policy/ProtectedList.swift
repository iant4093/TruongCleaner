/// Why a path is protected.
public enum ProtectedReason: Sendable, Hashable {
    /// macOS system folders and install/update staging.
    case system
    /// A folder we never delete itself: `/`, `~`, `~/Library`, a rule root.
    case root
    /// Apple app data such as Mail, Messages, Photos, Safari.
    case appleData
    /// iCloud, file providers, keychains and accounts.
    case syncAndIdentity
    /// Apple caches that break the system when removed.
    case fragileAppleCache
    /// State kept by AI agents and local model stores.
    case agentState
    /// Live interpreters and package stores that tools use directly.
    case liveStore
    /// Licensed audio/creative software and security agents.
    case licensedVendor
    /// Password managers and crypto wallets.
    case passwordManager
    /// A folder the user excluded in Settings.
    case userExcluded
}

/// One row of the global protected list (`docs/RULE_CATALOG.md` §3).
public struct ProtectedEntry: Sendable, Hashable {
    /// Path pattern. `~` is the home folder, `*` matches inside one component,
    /// `**` matches any number of components, and a trailing `/**` protects the
    /// folder and everything under it. A pattern without a wildcard is exact.
    public let pattern: String
    /// Why the matching paths are protected.
    public let reason: ProtectedReason
    /// Paths below the pattern's prefix that are not covered by this entry,
    /// written relative to it (`cache`, `Caches/Previews`). Only for patterns
    /// ending in `/**`.
    public let exceptions: [String]

    /// Creates an entry.
    public init(_ pattern: String, _ reason: ProtectedReason, except exceptions: [String] = []) {
        self.pattern = pattern
        self.reason = reason
        self.exceptions = exceptions
    }
}

/// The global protected list. It always wins over a rule's roots.
///
/// Rows follow `docs/RULE_CATALOG.md` §3 in order. Patterns that the catalog
/// gives without a location (for example `HomeKit`, `renv`, `*com.apple.coreaudio*`)
/// match at any depth. Names of vendors, password managers and wallets match at any
/// depth too, because their data lives in several places.
public enum ProtectedList {
    /// Every protected row.
    public static let entries: [ProtectedEntry] = system + roots + syncAndIdentity + appleData
        + fragileAppleCaches + agentState + liveStores + licensedVendors + passwordManagers

    private static let system: [ProtectedEntry] = [
        ProtectedEntry("/System/**", .system),
        ProtectedEntry("/usr/**", .system),
        ProtectedEntry("/opt/**", .system),
        ProtectedEntry("/bin/**", .system),
        ProtectedEntry("/sbin/**", .system),
        ProtectedEntry("/etc/**", .system),
        // `/etc` is a symlink to `/private/etc`; callers pass resolved paths.
        ProtectedEntry("/private/etc/**", .system),
        ProtectedEntry("/private/var/db/**", .system),
        ProtectedEntry("/private/var/vm/**", .system),
        ProtectedEntry("/Library/Updates/**", .system),
        ProtectedEntry("/macOS Install Data/**", .system),
        ProtectedEntry("/System/Volumes/Preboot/**", .system),
        ProtectedEntry("/Library/Apple/**", .system),
        ProtectedEntry("/Library/Keychains/**", .system),
        ProtectedEntry("/Library/Extensions/**", .system),
        ProtectedEntry("/Library/SystemExtensions/**", .system),
    ]

    private static let roots: [ProtectedEntry] = [
        ProtectedEntry("/", .root),
        ProtectedEntry("/Applications", .root),
        ProtectedEntry("/Library", .root),
        ProtectedEntry("/Users", .root),
        ProtectedEntry("/Users/Shared", .root),
        ProtectedEntry("~", .root),
        ProtectedEntry("~/Library", .root),
    ]

    private static let syncAndIdentity: [ProtectedEntry] = [
        ProtectedEntry("~/Library/Mobile Documents/**", .syncAndIdentity),
        ProtectedEntry("~/Library/CloudStorage/**", .syncAndIdentity),
        ProtectedEntry("~/Library/Caches/CloudKit/**", .syncAndIdentity),
        ProtectedEntry("~/Library/Caches/com.apple.bird/**", .syncAndIdentity),
        ProtectedEntry("~/Library/Caches/com.apple.cloudd/**", .syncAndIdentity),
        ProtectedEntry("~/Library/Caches/FileProvider/**", .syncAndIdentity),
        ProtectedEntry("~/Library/Application Support/FileProvider/**", .syncAndIdentity),
        ProtectedEntry("~/Library/Keychains/**", .syncAndIdentity),
        ProtectedEntry("~/Library/Accounts/**", .syncAndIdentity),
        ProtectedEntry("~/Library/Application Support/CloudDocs/**", .syncAndIdentity),
    ]

    private static let appleData: [ProtectedEntry] = [
        ProtectedEntry("~/Library/Mail/**", .appleData),
        // Rule `mail.messagesPreviews` may clean these two.
        ProtectedEntry("~/Library/Messages/**", .appleData, except: ["Caches/Previews", "StickerCache"]),
        ProtectedEntry("~/Library/Calendars/**", .appleData),
        ProtectedEntry("~/Library/Contacts/**", .appleData),
        // A Photos library can live anywhere (an external drive, `~/Movies`, a project folder).
        ProtectedEntry("**/*.photoslibrary/**", .appleData),
        // Notes keeps its real store in `group.com.apple.notes`; other Apple apps do the same.
        ProtectedEntry("~/Library/Group Containers/group.com.apple.*/**", .appleData),
        ProtectedEntry("~/Library/Safari/**", .appleData),
        ProtectedEntry("~/Library/Containers/com.apple.Notes/**", .appleData),
    ]

    private static let fragileAppleCaches: [ProtectedEntry] = [
        ProtectedEntry("~/Library/Caches/com.apple.FontRegistry*/**", .fragileAppleCache),
        ProtectedEntry("~/Library/Caches/com.apple.Spotlight*/**", .fragileAppleCache),
        ProtectedEntry("~/Library/Caches/com.apple.finder/**", .fragileAppleCache),
        ProtectedEntry("**/*com.apple.coreaudio*/**", .fragileAppleCache),
        ProtectedEntry("~/Library/Application Support/com.apple.idleassetsd/**", .fragileAppleCache),
        ProtectedEntry("~/Library/Application Support/com.apple.wallpaper/**", .fragileAppleCache),
        ProtectedEntry("**/com.apple.homed/**", .fragileAppleCache),
        ProtectedEntry("**/HomeKit/**", .fragileAppleCache),
        ProtectedEntry("**/FamilyCircle/**", .fragileAppleCache),
        ProtectedEntry("**/com.apple.containermanagerd/**", .fragileAppleCache),
    ]

    private static let agentState: [ProtectedEntry] = [
        ProtectedEntry("~/.claude/**", .agentState, except: ["cache", "paste-cache", "shell-snapshots"]),
        ProtectedEntry("~/.claude/**/worktrees/**", .agentState),
        ProtectedEntry("~/.codex/**", .agentState, except: ["cache", ".tmp"]),
        ProtectedEntry("~/.codex/**/worktrees/**", .agentState),
        ProtectedEntry("~/.kiro/**", .agentState),
        ProtectedEntry("~/.cursor/**", .agentState),
        ProtectedEntry("~/.ollama/models/**", .agentState),
        ProtectedEntry("~/.lmstudio/models/**", .agentState),
        ProtectedEntry("~/.cache/huggingface/**", .agentState),
        ProtectedEntry("~/.gemini/**", .agentState),
        ProtectedEntry("~/.continue/**", .agentState),
        ProtectedEntry("~/.codeium/**", .agentState),
        ProtectedEntry("~/.aider*/**", .agentState),
        ProtectedEntry("~/Library/Application Support/Claude/**", .agentState),
    ]

    private static let liveStores: [ProtectedEntry] = [
        ProtectedEntry("**/pypoetry/virtualenvs/**", .liveStore),
        ProtectedEntry("**/pnpm/dlx/**", .liveStore),
        ProtectedEntry("**/renv/**", .liveStore),
        ProtectedEntry("**/llama.cpp/**", .liveStore),
        ProtectedEntry("**/ms-playwright/**", .liveStore),
        ProtectedEntry("~/.yarn/berry/cache/**", .liveStore),
        ProtectedEntry("~/.cargo/registry/src/**", .liveStore),
        ProtectedEntry("~/.cargo/registry/index/**", .liveStore),
        ProtectedEntry("~/.cargo/git/**", .liveStore),
    ]

    private static let licensedVendors: [ProtectedEntry] = [
        ProtectedEntry("**/*izotope*/**", .licensedVendor),
        ProtectedEntry("**/Native Instruments/**", .licensedVendor),
        ProtectedEntry("**/com.native-instruments.*/**", .licensedVendor),
        ProtectedEntry("**/Avid/**", .licensedVendor),
        ProtectedEntry("**/com.avid.*/**", .licensedVendor),
        ProtectedEntry("**/*fabfilter*/**", .licensedVendor),
        ProtectedEntry("**/PACE/**", .licensedVendor),
        ProtectedEntry("**/PACE Anti-Piracy/**", .licensedVendor),
        ProtectedEntry("**/*ilok*/**", .licensedVendor),
        ProtectedEntry("**/Library/Caches/Adobe*/**", .licensedVendor),
        ProtectedEntry("**/*crowdstrike*/**", .licensedVendor),
        ProtectedEntry("**/*sentinelone*/**", .licensedVendor),
        ProtectedEntry("**/*intego*/**", .licensedVendor),
        ProtectedEntry("**/*symantec*/**", .licensedVendor),
        ProtectedEntry("**/*jamf*/**", .licensedVendor),
    ]

    private static let passwordManagers: [ProtectedEntry] = [
        ProtectedEntry("**/*1password*/**", .passwordManager),
        ProtectedEntry("**/*bitwarden*/**", .passwordManager),
        ProtectedEntry("**/*keepassxc*/**", .passwordManager),
        ProtectedEntry("**/*dashlane*/**", .passwordManager),
        ProtectedEntry("**/*ledger live*/**", .passwordManager),
        ProtectedEntry("**/*ledger-live*/**", .passwordManager),
        ProtectedEntry("**/*exodus*/**", .passwordManager),
        ProtectedEntry("**/*wasabi*/**", .passwordManager),
        ProtectedEntry("**/*enpass*/**", .passwordManager),
        ProtectedEntry("**/*strongbox*/**", .passwordManager),
        ProtectedEntry("**/*macpass*/**", .passwordManager),
        ProtectedEntry("**/*keepersecurity*/**", .passwordManager),
        ProtectedEntry("**/com.callpod.*/**", .passwordManager),
        ProtectedEntry("**/Keeper Password Manager/**", .passwordManager),
        ProtectedEntry("**/*nordpass*/**", .passwordManager),
        ProtectedEntry("**/*proton pass*/**", .passwordManager),
        ProtectedEntry("**/*protonpass*/**", .passwordManager),
        ProtectedEntry("**/me.proton.pass*/**", .passwordManager),
        ProtectedEntry("**/*lastpass*/**", .passwordManager),
        ProtectedEntry("**/*roboform*/**", .passwordManager),
        ProtectedEntry("**/Application Support/Bitcoin/**", .passwordManager),
        ProtectedEntry("~/.bitcoin/**", .passwordManager),
        ProtectedEntry("**/*electrum*/**", .passwordManager),
        ProtectedEntry("**/*sparrow*/**", .passwordManager),
    ]
}

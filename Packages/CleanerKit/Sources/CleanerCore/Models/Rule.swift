import Foundation

/// One row of `docs/RULE_CATALOG.md` §4: what to look for, where, and what may happen to it.
///
/// `LocalizedStringResource` is not `Hashable`, so equality and hashing use `id` only.
public struct Rule: Sendable, Identifiable, Hashable {
    /// Stable ID such as `dev.xcodeDerivedData`. Used in history and settings.
    public let id: String
    /// Sidebar group.
    public let category: Category
    /// How safe the items are to remove.
    public let tier: Tier
    /// Folders the rule may look in. Nothing outside them is ever offered.
    public let roots: [RootSpec]
    /// What inside a root counts.
    public let match: MatchSpec
    /// How deep to look under a root for matches. Sizing always goes all the way down.
    public let depth: Int
    /// Extra conditions for an item.
    public let guards: Guards
    /// Access the rule needs.
    public let access: Access
    /// What happens to an approved item.
    public let action: Action
    /// Short name shown in the UI.
    public let title: LocalizedStringResource
    /// One plain sentence: what it is and what happens if removed.
    public let explain: LocalizedStringResource
    /// Info rows: the exact command text for the "Copy Command" button. The app never runs it.
    /// Nil when the sanctioned fix is not a Terminal command.
    public let sanctionedCommand: String?
    /// Info rows: the System Settings pane that holds the sanctioned fix, for "Open Settings".
    /// Nil when the catalog names no pane.
    public let settingsURL: URL?

    /// Creates a rule.
    public init(
        id: String,
        category: Category,
        tier: Tier,
        roots: [RootSpec],
        match: MatchSpec,
        depth: Int = 1,
        guards: Guards = Guards(),
        access: Access,
        action: Action,
        title: LocalizedStringResource,
        explain: LocalizedStringResource,
        sanctionedCommand: String? = nil,
        settingsURL: URL? = nil
    ) {
        self.id = id
        self.category = category
        self.tier = tier
        self.roots = roots
        self.match = match
        self.depth = depth
        self.guards = guards
        self.access = access
        self.action = action
        self.title = title
        self.explain = explain
        self.sanctionedCommand = sanctionedCommand
        self.settingsURL = settingsURL
    }

    /// ID of the catalog rule whose items may be whole `.app` bundles: the macOS installer apps.
    public static let wholeBundleRuleID = "installers.macOS"

    /// ID of the synthetic rule built by `UninstallRule`, the second rule that may remove a whole `.app`.
    public static let uninstallRuleID = "apps.uninstall"

    /// True only for `installers.macOS` and `apps.uninstall`. Callers pass it as
    /// `GateContext.allowWholeBundle`: the app may be removed as a whole, and nothing inside any bundle
    /// may be touched. It is decided by the rule's ID, so no other rule can gain it by accident.
    public var allowsWholeBundle: Bool {
        id == Self.wholeBundleRuleID || id == Self.uninstallRuleID
    }

    /// Rules are equal when their IDs are equal. IDs are unique in the catalog.
    public static func == (lhs: Rule, rhs: Rule) -> Bool {
        lhs.id == rhs.id
    }

    /// Hashes the ID only, matching `==`.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// One item a scan found for a rule, with the identity it had at scan time.
public struct Finding: Sendable, Identifiable {
    /// Unique per finding.
    public let id: UUID
    /// ID of the rule that produced this finding.
    public let ruleID: String
    /// Location of the item.
    public let url: URL
    /// File system ID (`ATTR_CMN_FSID`) at scan time. Compared again just before any action.
    public let fsid: UInt64
    /// File ID at scan time. Compared again just before any action.
    public let fileID: UInt64
    /// Allocated bytes on disk (not logical size).
    public let allocatedBytes: Int64
    /// Bytes that only this item owns (not shared with APFS clones). Used for "space to be freed".
    public let privateBytes: Int64
    /// Newest modification date found inside the item, if readable.
    public let newestModification: Date?
    /// Whether the item is a folder.
    public let isDirectory: Bool
    /// Whether the item itself is a symbolic link.
    public let isSymlink: Bool
    /// BSD file flags at scan time (`st_flags`), for example `UF_IMMUTABLE`.
    public let flags: UInt32
    /// Number of file system entries inside the item, including the item itself.
    public let itemCount: Int

    /// Creates a finding.
    public init(
        id: UUID = UUID(),
        ruleID: String,
        url: URL,
        fsid: UInt64,
        fileID: UInt64,
        allocatedBytes: Int64,
        privateBytes: Int64,
        newestModification: Date?,
        isDirectory: Bool,
        isSymlink: Bool,
        flags: UInt32,
        itemCount: Int
    ) {
        self.id = id
        self.ruleID = ruleID
        self.url = url
        self.fsid = fsid
        self.fileID = fileID
        self.allocatedBytes = allocatedBytes
        self.privateBytes = privateBytes
        self.newestModification = newestModification
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.flags = flags
        self.itemCount = itemCount
    }
}

import Foundation

/// A folder a rule may look in, described relative to a base so it can be
/// expanded against a fixture home in tests.
public struct RootSpec: Sendable, Hashable {
    /// What the path components are relative to.
    public enum Base: Sendable, Hashable {
        /// The user's home folder.
        case home
        /// The file system root. Components describe an absolute path.
        case absolute
        /// `DARWIN_USER_CACHE_DIR` (under `/private/var/folders`).
        case darwinUserCache
        /// `DARWIN_USER_TEMP_DIR` (under `/private/var/folders`).
        case darwinUserTemp
        /// Each folder in `Environment.projectFolders`, which the user picked in Settings.
        /// `components` are relative to each of those folders and are normally empty, so the root
        /// is the chosen folder itself. No chosen folder means no root.
        case userChosen
    }

    /// What `components` are relative to.
    public var base: Base
    /// Path components below the base. A `"*"` component matches any one folder name.
    public var components: [String]
    /// Apps or processes that must be closed before anything under this root is removed.
    /// They are added to the rule's own `Guards.owners` for items under this root only.
    public var owners: [OwnerSpec]

    /// Creates a root description.
    public init(base: Base, components: [String], owners: [OwnerSpec] = []) {
        self.base = base
        self.components = components
        self.owners = owners
    }
}

/// The app or process that owns a rule's data and must be closed before cleaning.
public enum OwnerSpec: Sendable, Hashable {
    /// A GUI app, by bundle identifier.
    case bundleID(String)
    /// A command-line process, by executable name.
    case processName(String)
    /// The candidate's own top-level folder name, read as a bundle identifier when it
    /// looks like one (at least three dot-separated parts, e.g. `com.example.App`).
    /// Used by rules such as `user.caches`, where each child folder belongs to one app.
    /// A name that does not look like a bundle ID has no owner from this spec.
    ///
    /// - Parameter stripSuffix: A suffix removed from the name first (compared without regard
    ///   to case), for folders such as `com.example.App.savedState`. Nil reads the name as it is.
    case childNameAsBundleID(stripSuffix: String?)
    /// The path component at `index` of the expanded root, read as a bundle identifier.
    ///
    /// `index` counts the components of the matching `RootSpec` (the ones after its base), so
    /// for `Library/Containers/*/Data/Library/Caches` the `*` is index 2. The same rule applies
    /// as for `childNameAsBundleID`: a segment that does not look like a bundle ID has no owner.
    case rootSegmentAsBundleID(index: Int)
}

/// A fixed command that frees space through its owner's own tool.
///
/// The executable path must be absolute and come from a fixed list. The
/// command is never run through a shell.
public struct OwnerCommandSpec: Sendable, Hashable {
    /// The command's ID in the runner's allow-list, for example `"brew.cleanup"`.
    ///
    /// `CleanerCore` cannot see the allow-list (`CleanerActions.OwnerCommands`), so the ID is plain
    /// text. A test in `CleanerActionsTests` checks that every catalog ID is known to the runner.
    public var id: String
    /// Absolute path of the executable.
    public var executable: URL
    /// Argument vector, without the executable. For the per-item simulator commands this is the
    /// fixed part; the runner adds the validated device or runtime identifier itself.
    public var arguments: [String]
    /// Longest time the command may run.
    public var timeout: Duration
    /// Commands that run after this one, in order, when a rule needs more than one
    /// (`dev.dockerDangling`). Each has its own ID in the allow-list.
    public var followUps: [OwnerCommandSpec]

    /// Creates a command description.
    public init(
        id: String,
        executable: URL,
        arguments: [String],
        timeout: Duration,
        followUps: [OwnerCommandSpec] = []
    ) {
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.followUps = followUps
    }
}

/// What inside a root counts as a match.
public enum MatchSpec: Sendable, Hashable {
    /// Each direct child of the root.
    case children
    /// A glob pattern relative to the root.
    case glob(String)
    /// Files with one of these extensions.
    case files(extensions: Set<String>)
    /// Nothing is walked; the owner's command frees the space.
    case ownerCommand(OwnerCommandSpec)
    /// Info rows: size the root and show it.
    case measureOnly
    /// Info rows with no folder to walk. The key names a value that the System Data page works out
    /// itself (for example the snapshot list). Nothing is walked and nothing is offered.
    /// Only Info rules use it, and such a rule has no roots.
    case computed(String)
}

/// Extra conditions an item must meet to be offered.
public struct Guards: Sendable, Hashable {
    /// Only items whose newest modification inside is older than this.
    public var minAge: Duration?
    /// Keep the N newest matches of each group.
    public var keepNewest: Int?
    /// Apps or processes that must not be running. Unknown state means keep.
    public var owners: [OwnerSpec]
    /// Names that must exist beside the item (for example `Cargo.toml` beside `target`).
    public var requiresSibling: [String]
    /// Rule-local exclusions on top of the global protected list.
    public var excludeNames: Set<String>
    /// Name patterns (a single `*` is allowed, case-insensitive) matched against the folder
    /// names that a `*` in a root stands for. A root with a matching name is not scanned at all.
    /// For example `com.apple.*` leaves out `Containers/com.apple.Notes/...`.
    public var excludeRootSegments: [String]
    /// Like `requiresSibling`, but only for items with a given name (compared without regard to
    /// case): the key is the item's name, the value lists names of which one must exist beside it.
    /// Items with other names need nothing from this guard. For example `target` needs `Cargo.toml`.
    public var requiresSiblingByName: [String: [String]]
    /// Names that must not exist directly inside the item (for example `.git`, so nested
    /// repositories are kept). Compared without regard to case.
    ///
    /// Needs the item's folder listing. An item whose inside the scan did not reach (at the
    /// rule's maximum depth) cannot be checked, so it is kept.
    public var skipIfContains: Set<String>

    /// Creates a set of guards. All default to "no extra condition".
    public init(
        minAge: Duration? = nil,
        keepNewest: Int? = nil,
        owners: [OwnerSpec] = [],
        requiresSibling: [String] = [],
        excludeNames: Set<String> = [],
        excludeRootSegments: [String] = [],
        requiresSiblingByName: [String: [String]] = [:],
        skipIfContains: Set<String> = []
    ) {
        self.minAge = minAge
        self.keepNewest = keepNewest
        self.owners = owners
        self.requiresSibling = requiresSibling
        self.excludeNames = excludeNames
        self.excludeRootSegments = excludeRootSegments
        self.requiresSiblingByName = requiresSiblingByName
        self.skipIfContains = skipIfContains
    }

    /// Whether the matcher needs the names inside each folder (`Matcher.evaluate`'s `siblingNames`)
    /// to apply these guards.
    public var needsFolderListings: Bool {
        !requiresSibling.isEmpty || !requiresSiblingByName.isEmpty || !skipIfContains.isEmpty
    }
}

/// What the app does with an approved item.
public enum Action: Sendable, Hashable {
    /// Move to the Trash.
    case trash
    /// Delete for good. For items that are already in a Trash, where moving them is meaningless.
    /// The executor asks for the explicit confirmation required by `safety.md` rule 11.
    case deletePermanently
    /// Run the owner's own command.
    case ownerCommand(OwnerCommandSpec)
    /// Nothing. Info rows only.
    case none
}

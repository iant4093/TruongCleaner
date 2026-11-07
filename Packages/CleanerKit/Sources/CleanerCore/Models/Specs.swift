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
    }

    /// What `components` are relative to.
    public var base: Base
    /// Path components below the base. A `"*"` component matches any one folder name.
    public var components: [String]

    /// Creates a root description.
    public init(base: Base, components: [String]) {
        self.base = base
        self.components = components
    }
}

/// The app or process that owns a rule's data and must be closed before cleaning.
public enum OwnerSpec: Sendable, Hashable {
    /// A GUI app, by bundle identifier.
    case bundleID(String)
    /// A command-line process, by executable name.
    case processName(String)
}

/// A fixed command that frees space through its owner's own tool.
///
/// The executable path must be absolute and come from a fixed list. The
/// command is never run through a shell.
public struct OwnerCommandSpec: Sendable, Hashable {
    /// Absolute path of the executable.
    public var executable: URL
    /// Argument vector, without the executable.
    public var arguments: [String]
    /// Longest time the command may run.
    public var timeout: Duration

    /// Creates a command description.
    public init(executable: URL, arguments: [String], timeout: Duration) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
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

    /// Creates a set of guards. All default to "no extra condition".
    public init(
        minAge: Duration? = nil,
        keepNewest: Int? = nil,
        owners: [OwnerSpec] = [],
        requiresSibling: [String] = [],
        excludeNames: Set<String> = []
    ) {
        self.minAge = minAge
        self.keepNewest = keepNewest
        self.owners = owners
        self.requiresSibling = requiresSibling
        self.excludeNames = excludeNames
    }
}

/// What the app does with an approved item.
public enum Action: Sendable, Hashable {
    /// Move to the Trash.
    case trash
    /// Run the owner's own command.
    case ownerCommand(OwnerCommandSpec)
    /// Nothing. Info rows only.
    case none
}

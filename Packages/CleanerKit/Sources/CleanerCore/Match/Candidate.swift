import Foundation

/// One entry as the scanner saw it, before any rule decides whether to offer it.
public struct Candidate: Sendable {
    /// Location of the entry.
    public var url: URL
    /// Depth below the expanded root. The root itself is 0, its children are 1.
    public var depth: Int
    /// File system ID at scan time.
    public var fsid: UInt64
    /// File ID at scan time.
    public var fileID: UInt64
    /// Whether the entry is a folder.
    public var isDirectory: Bool
    /// Whether the entry itself is a symbolic link (the scanner never follows it).
    public var isSymlink: Bool
    /// BSD file flags at scan time.
    public var flags: UInt32
    /// Allocated bytes on disk, including everything inside a folder.
    public var allocatedBytes: Int64
    /// Bytes not shared with APFS clones.
    public var privateBytes: Int64
    /// Number of file system entries inside, including the entry itself.
    public var itemCount: Int
    /// Newest modification date found inside, or nil if it could not be read.
    public var newestModification: Date?

    /// Creates a candidate.
    public init(
        url: URL,
        depth: Int,
        fsid: UInt64,
        fileID: UInt64,
        isDirectory: Bool,
        isSymlink: Bool,
        flags: UInt32,
        allocatedBytes: Int64,
        privateBytes: Int64,
        itemCount: Int,
        newestModification: Date?
    ) {
        self.url = url
        self.depth = depth
        self.fsid = fsid
        self.fileID = fileID
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.flags = flags
        self.allocatedBytes = allocatedBytes
        self.privateBytes = privateBytes
        self.itemCount = itemCount
        self.newestModification = newestModification
    }
}

/// What the matcher decided for a candidate that fit the rule's shape.
public enum MatchOutcome: Sendable {
    /// The candidate is offered.
    case finding(Finding)
    /// The candidate is not offered, for this reason.
    case skipped(Candidate, SkipReason)
}

/// Why the matcher did not offer a candidate.
public enum SkipReason: String, Sendable, Codable {
    /// The candidate is not inside the rule's root.
    case outsideRoots
    /// The global protected list or a user exclusion covers it.
    case protectedPath
    /// It is the rule's root, `~`, `~/Library` or another folder we never delete itself.
    case isRoot
    /// Newer than the rule's `minAge`.
    case tooNew
    /// One of the N newest in its folder, which the rule keeps.
    case keepNewest
    /// The rule has a `minAge` and the modification date is unknown.
    case unknownAge
    /// A name on the path matches the rule's `excludeNames`.
    case excludedName
    /// A symbolic link, which this rule does not allow.
    case symlinkNotAllowed
    /// The file the rule requires beside the item is missing or unknown.
    case missingSibling
    /// An Info rule never offers anything to delete.
    case infoRule
}

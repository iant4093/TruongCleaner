import Foundation

/// Settings for one `BulkWalker.walk` call.
public struct WalkOptions: Sendable {
    /// Number of worker threads. Clamped to `1...min(8, activeProcessorCount)` when the walk starts.
    public var maxWorkers: Int
    /// Folder totals are kept for every entry at depth `0...totalsDepth` below the root (root = 0).
    /// Deeper entries are added into their nearest kept ancestor and are not kept individually.
    public var totalsDepth: Int
    /// Size of the largest-files list. 0 turns it off.
    public var topFilesCount: Int
    /// Stop after this long and return a partial result. `nil` means no limit.
    public var limit: Duration?
    /// Smallest time between two progress callbacks.
    public var progressInterval: Duration

    /// Creates walk options.
    public init(
        maxWorkers: Int = min(8, ProcessInfo.processInfo.activeProcessorCount),
        totalsDepth: Int = 1,
        topFilesCount: Int = 0,
        limit: Duration? = nil,
        progressInterval: Duration = .milliseconds(100)
    ) {
        self.maxWorkers = maxWorkers
        self.totalsDepth = totalsDepth
        self.topFilesCount = topFilesCount
        self.limit = limit
        self.progressInterval = progressInterval
    }
}

/// Identity of a file system entry: the volume (`ATTR_CMN_FSID`) and the file ID on that volume.
public struct EntryID: Sendable, Hashable {
    /// The volume's `fsid_t`, packed as `val[0] << 32 | val[1]`.
    public let fsid: UInt64
    /// The entry's file ID (inode number).
    public let fileID: UInt64

    /// Creates an entry ID.
    public init(fsid: UInt64, fileID: UInt64) {
        self.fsid = fsid
        self.fileID = fileID
    }
}

/// Totals for one kept folder or file.
///
/// Folder totals cover the whole subtree. A file or folder with several hard
/// links adds its bytes only to the first place the walk meets it, so which
/// folder holds those bytes can differ between runs. The root total is exact.
public struct NodeTotal: Sendable {
    /// What kind of entry this is.
    public enum Kind: Sendable, Hashable {
        case directory
        case file
        case symlink
        /// FIFO, socket, or device node.
        case other
    }

    /// Location of the entry.
    public let url: URL
    /// 0 for the root, 1 for its direct children, and so on.
    public let depth: Int
    /// Volume and file ID.
    public let id: EntryID
    /// Entry kind.
    public let kind: Kind
    /// File flags as returned by `ATTR_CMN_FLAGS` (the `st_flags` bits).
    public let flags: UInt32
    /// Allocated bytes on disk for the whole subtree.
    public var allocatedBytes: Int64
    /// Bytes that deleting this subtree alone would free (`ATTR_CMNEXT_PRIVATESIZE`).
    /// Clone-shared blocks are not counted. Equals `allocatedBytes` where macOS does not report it.
    public var privateBytes: Int64
    /// Number of files in the subtree (everything that is not a folder or a symlink; hard-link duplicates excluded).
    public var fileCount: Int
    /// Newest modification date of the entry itself or anything inside it, folders included.
    /// `nil` when no date could be read.
    public var newestModification: Date?

    /// Creates a node total.
    public init(
        url: URL, depth: Int, id: EntryID, kind: Kind, flags: UInt32,
        allocatedBytes: Int64, privateBytes: Int64, fileCount: Int, newestModification: Date?
    ) {
        self.url = url
        self.depth = depth
        self.id = id
        self.kind = kind
        self.flags = flags
        self.allocatedBytes = allocatedBytes
        self.privateBytes = privateBytes
        self.fileCount = fileCount
        self.newestModification = newestModification
    }
}

/// Everything a walk found.
public struct WalkResult: Sendable {
    /// The folder that was walked.
    public let root: URL
    /// Kept totals, sorted by depth and then path. The root is first.
    public let nodes: [NodeTotal]
    /// The largest files by allocated size, largest first. Empty when `topFilesCount` is 0.
    public let topFiles: [NodeTotal]
    /// Files seen (everything that is not a folder or symlink), each hard-linked file once.
    public let files: Int
    /// Folders entered, root included.
    public let directories: Int
    /// Symbolic links seen. They are never followed and add no bytes.
    public let symlinks: Int
    /// Extra names of hard-linked files that were not counted again.
    public let hardLinkDuplicates: Int
    /// Entries skipped because they are on another volume.
    public let crossVolumeSkipped: Int
    /// Folders macOS would not open (`EPERM`/`EACCES`), sorted by path, at most 500. Their size is unknown, not zero.
    public let deniedDirectories: [URL]
    /// How many folders were denied, including those past the 500 listed.
    public let deniedCount: Int
    /// Errors other than permission (vanished entries, unreadable attributes, too many open files).
    public let otherErrors: Int
    /// Files for which macOS did not report a private size; their allocated size was used instead.
    public let privateSizeMissing: Int
    /// True when the walk was cancelled or hit its time limit before it finished.
    public let partial: Bool

    init(
        root: URL, nodes: [NodeTotal], topFiles: [NodeTotal], files: Int, directories: Int, symlinks: Int,
        hardLinkDuplicates: Int, crossVolumeSkipped: Int, deniedDirectories: [URL], deniedCount: Int,
        otherErrors: Int, privateSizeMissing: Int, partial: Bool
    ) {
        self.root = root
        self.nodes = nodes
        self.topFiles = topFiles
        self.files = files
        self.directories = directories
        self.symlinks = symlinks
        self.hardLinkDuplicates = hardLinkDuplicates
        self.crossVolumeSkipped = crossVolumeSkipped
        self.deniedDirectories = deniedDirectories
        self.deniedCount = deniedCount
        self.otherErrors = otherErrors
        self.privateSizeMissing = privateSizeMissing
        self.partial = partial
    }
}

/// A progress snapshot passed to the callback of `BulkWalker.walk`.
public struct WalkProgress: Sendable {
    /// Files counted so far.
    public let files: Int
    /// Allocated bytes counted so far.
    public let allocatedBytes: Int64
    /// A folder being read right now.
    public let currentPath: URL?

    init(files: Int, allocatedBytes: Int64, currentPath: URL?) {
        self.files = files
        self.allocatedBytes = allocatedBytes
        self.currentPath = currentPath
    }
}

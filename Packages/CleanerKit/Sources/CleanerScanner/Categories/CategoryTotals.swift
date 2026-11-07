import Foundation

/// A part of the Data volume that the Overview bar and the System Data page account for.
///
/// Every byte the category scanner finds lands in exactly one of these.
public enum StorageCategory: String, Sendable, CaseIterable {
    /// `/Applications` and `~/Applications`.
    case applications
    /// `~/Documents`.
    case documents
    /// `~/Downloads`.
    case downloads
    /// `~/Desktop`.
    case desktop
    /// `~/Pictures`, including Photos libraries stored there.
    case pictures
    /// `~/Movies`.
    case movies
    /// `~/Music`.
    case music
    /// `~/Library/Mobile Documents`. Files that iCloud has evicted use no space and count as 0.
    case icloud
    /// `~/Library/Caches`.
    case libraryCaches
    /// The rest of `~/Library` (application data, containers, preferences).
    case libraryOther
    /// `~/Library/Developer` (Xcode, simulators).
    case developer
    /// `~/Library/Application Support/MobileSync/Backup`.
    case iosBackups
    /// `~/Library/Mail` and Mail's container.
    case mail
    /// `~/Library/Messages`.
    case messages
    /// `~/.Trash`.
    case trash
    /// The rest of the home folder.
    case otherHome
    /// Other users' home folders and `/Users/Shared`.
    case otherUsers
}

/// What the category scanner reports while it works.
public struct CategoryProgress: Sendable {
    /// The category being measured right now.
    public let category: StorageCategory
    /// Allocated bytes counted so far, over all categories.
    public let measuredBytes: Int64

    init(category: StorageCategory, measuredBytes: Int64) {
        self.category = category
        self.measuredBytes = measuredBytes
    }
}

/// How many bytes each ``StorageCategory`` uses, measured by our own walker.
///
/// Sizes are allocated bytes on disk. Each file is counted in one category. Hard links are
/// counted once inside one walked folder, but a file hard-linked between two top-level folders
/// is counted in both.
public struct CategoryTotals: Sendable {
    /// Allocated bytes per category. Every category has an entry; `0` means nothing was found or nothing could be read
    /// (check ``needsAccess``).
    public var bytes: [StorageCategory: Int64]
    /// Bytes that deleting the category alone would free (clone-shared blocks excluded).
    public var privateBytes: [StorageCategory: Int64]
    /// Folders macOS would not open, per category. Their size is unknown, and is not in ``bytes``.
    public var needsAccess: [StorageCategory: Int]
    /// True when the measurement was cancelled or a folder failed to open for a reason other than permission.
    public let partial: Bool
    /// How long the measurement took.
    public let duration: Duration
    /// When the measurement finished.
    public let measuredAt: Date

    /// Creates totals. Categories missing from a dictionary are filled with zero.
    public init(
        bytes: [StorageCategory: Int64],
        privateBytes: [StorageCategory: Int64],
        needsAccess: [StorageCategory: Int],
        partial: Bool,
        duration: Duration,
        measuredAt: Date = Date()
    ) {
        func filled<Value: Numeric>(_ values: [StorageCategory: Value]) -> [StorageCategory: Value] {
            var result = values
            for category in StorageCategory.allCases where result[category] == nil { result[category] = 0 }
            return result
        }
        self.bytes = filled(bytes)
        self.privateBytes = filled(privateBytes)
        self.needsAccess = filled(needsAccess)
        self.partial = partial
        self.duration = duration
        self.measuredAt = measuredAt
    }

    /// Allocated bytes of one category.
    public func bytes(of category: StorageCategory) -> Int64 {
        bytes[category] ?? 0
    }

    /// Allocated bytes of all categories together.
    public var totalBytes: Int64 {
        bytes.values.reduce(0, +)
    }

    /// Private bytes of all categories together.
    public var totalPrivateBytes: Int64 {
        privateBytes.values.reduce(0, +)
    }

    /// Folders that could not be opened, over all categories.
    public var totalNeedsAccess: Int {
        needsAccess.values.reduce(0, +)
    }
}

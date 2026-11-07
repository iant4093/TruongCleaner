import Foundation

/// What to look for: which folders, how big, and how long untouched.
public struct LargeFileQuery: Sendable {
    /// Folders to search. Each must be a real folder, not a symbolic link.
    public var roots: [URL]
    /// Smallest allocated size, in bytes, that counts as large.
    public var minBytes: Int64
    /// Only files last modified before this date. `nil` accepts any date. A file whose
    /// date could not be read is left out when this is set.
    public var notModifiedSince: Date?
    /// Most files to return.
    public var limit: Int

    /// Creates a query.
    public init(roots: [URL], minBytes: Int64, notModifiedSince: Date? = nil, limit: Int = 500) {
        self.roots = roots
        self.minBytes = minBytes
        self.notModifiedSince = notModifiedSince
        self.limit = limit
    }
}

/// One large file found by ``LargeFileFinder``.
public struct LargeFile: Sendable, Identifiable {
    /// Volume and file ID. Two names for the same hard-linked file share one ID.
    public let id: EntryID
    /// Where the file is.
    public let url: URL
    /// Allocated bytes on disk.
    public let allocatedBytes: Int64
    /// Bytes that deleting this file would free (clone-shared blocks are not counted).
    public let privateBytes: Int64
    /// Modification date, or `nil` if it could not be read. This is not the "last opened" date.
    public let modified: Date?

    /// Creates a large file entry.
    public init(id: EntryID, url: URL, allocatedBytes: Int64, privateBytes: Int64, modified: Date?) {
        self.id = id
        self.url = url
        self.allocatedBytes = allocatedBytes
        self.privateBytes = privateBytes
        self.modified = modified
    }
}

/// A progress snapshot passed to the callback of ``LargeFileFinder``.
public struct LargeFileProgress: Sendable {
    /// Files counted so far, across all folders searched so far.
    public let files: Int
    /// A folder being read right now.
    public let currentPath: URL?

    /// Creates a progress snapshot.
    public init(files: Int, currentPath: URL?) {
        self.files = files
        self.currentPath = currentPath
    }
}

/// Everything a large-file search found, including what it could not read.
public struct LargeFileReport: Sendable {
    /// Matching files, largest first, at most `limit`.
    public let files: [LargeFile]
    /// Folders macOS would not open (`EPERM`/`EACCES`), search roots included. Their contents
    /// are unknown, not empty.
    public let needsAccess: [URL]
    /// Search roots that were skipped because they are missing, not a folder, or a symbolic link.
    public let skippedRoots: [URL]
    /// True when the search was stopped before it finished.
    public let partial: Bool
    /// True when the search keeps only the largest files it sees and may have dropped smaller
    /// files that also match. Raise the minimum size or narrow the folders to see them.
    public let mayBeMissingFiles: Bool

    /// Creates a report.
    public init(files: [LargeFile], needsAccess: [URL], skippedRoots: [URL], partial: Bool, mayBeMissingFiles: Bool) {
        self.files = files
        self.needsAccess = needsAccess
        self.skippedRoots = skippedRoots
        self.partial = partial
        self.mayBeMissingFiles = mayBeMissingFiles
    }
}

/// Finds big files that have not been modified for a while. Reads only; never changes anything.
public enum LargeFileFinder {
    /// The walker keeps this many of the largest files per folder searched, at least.
    private static let minimumCandidates = 500
    /// Cap so a huge `limit` cannot ask the walker for an unbounded list (four times the limit, so at most this).
    private static let maximumCandidates = 100_000

    /// Searches the query's folders off the main actor and returns the matching files.
    ///
    /// - Throws: `ScanError` when no folder in the query could be searched.
    @concurrent
    public static func find(
        _ query: LargeFileQuery,
        progress: (@Sendable (LargeFileProgress) -> Void)? = nil
    ) async throws -> [LargeFile] {
        try await search(query, progress: progress).files
    }

    /// Like ``find(_:progress:)`` but also reports folders that need access, skipped roots and
    /// whether the search was cut short.
    ///
    /// Folders are searched one after another. When the calling task is cancelled the search stops
    /// within about 100 ms and returns what it has with `partial == true`.
    ///
    /// - Parameters:
    ///   - query: Folders and filters.
    ///   - progress: Called at most about 10 times per second, from a worker thread. Keep it short.
    /// - Throws: The `ScanError` of the first folder when none of the query's folders could be searched.
    @concurrent
    public static func search(
        _ query: LargeFileQuery,
        progress: (@Sendable (LargeFileProgress) -> Void)? = nil
    ) async throws -> LargeFileReport {
        guard query.limit > 0, !query.roots.isEmpty else {
            return LargeFileReport(files: [], needsAccess: [], skippedRoots: [], partial: false, mayBeMissingFiles: false)
        }

        let candidates = max(min(query.limit, maximumCandidates / 4) * 4, minimumCandidates)
        let options = WalkOptions(totalsDepth: 0, topFilesCount: candidates)

        var matches: [LargeFile] = []
        var seen = Set<EntryID>()
        var needsAccess: [URL] = []
        var skippedRoots: [URL] = []
        var firstError: ScanError?
        var walked = 0
        var filesSoFar = 0
        var partial = false
        var mayBeMissing = false

        for root in query.roots {
            if Task.isCancelled {
                partial = true
                break
            }
            let base = filesSoFar
            var forward: (@Sendable (WalkProgress) -> Void)?
            if let progress {
                forward = { @Sendable walk in
                    progress(LargeFileProgress(files: base + walk.files, currentPath: walk.currentPath))
                }
            }
            let result: WalkResult
            do {
                result = try await BulkWalker.walk(root, options: options, progress: forward)
            } catch let error as ScanError {
                firstError = firstError ?? error
                if case .accessDenied = error { needsAccess.append(root) } else { skippedRoots.append(root) }
                continue
            }
            walked += 1
            filesSoFar += result.files
            partial = partial || result.partial
            needsAccess.append(contentsOf: result.deniedDirectories)

            // A full list whose smallest entry still qualifies may have dropped other qualifying files.
            if result.topFiles.count >= candidates, let smallest = result.topFiles.last,
                smallest.allocatedBytes >= query.minBytes
            {
                mayBeMissing = true
            }

            for node in result.topFiles where node.kind == .file && node.allocatedBytes >= query.minBytes {
                if let cutoff = query.notModifiedSince {
                    // Unknown means keep: a file without a readable date is not offered as "old".
                    guard let modified = node.newestModification, modified < cutoff else { continue }
                }
                guard seen.insert(node.id).inserted else { continue }
                matches.append(
                    LargeFile(
                        id: node.id, url: node.url, allocatedBytes: node.allocatedBytes,
                        privateBytes: node.privateBytes, modified: node.newestModification))
            }
        }

        if walked == 0, !partial, let firstError { throw firstError }

        matches.sort {
            $0.allocatedBytes != $1.allocatedBytes ? $0.allocatedBytes > $1.allocatedBytes : $0.url.path < $1.url.path
        }
        if matches.count > query.limit {
            matches.removeSubrange(query.limit...)
            mayBeMissing = true
        }
        return LargeFileReport(
            files: matches, needsAccess: needsAccess, skippedRoots: skippedRoots,
            partial: partial, mayBeMissingFiles: mayBeMissing)
    }
}

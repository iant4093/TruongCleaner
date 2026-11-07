import CleanerCore
import Darwin
import Foundation

/// One look at every process's open files, answered many times.
///
/// `ProcessOpenFilesProvider` takes a new snapshot on each call (about 120 ms). A clean asks about
/// hundreds of items, so `Cleaner` takes one snapshot per run and refreshes it now and then.
/// The snapshot records, for each process, its open files, current folder and root folder,
/// and answers `hasOpenFiles(under:)` from memory.
///
/// A snapshot that could not be taken, or that missed a process it failed to read, never answers
/// "nothing is open": the answer is `nil`, which the gate treats as "keep".
/// Processes the user may not inspect (other users', system daemons) cannot be seen and are skipped,
/// as in `ProcessOpenFilesProvider`. A file opened after the snapshot is not seen.
/// The reading itself lives in ``ProcessInspector``; this type only stores and answers.
public struct OpenFilesSnapshot: OpenFilesProvider {
    /// How complete the snapshot is.
    enum Completeness: Sendable, Equatable {
        /// Every process was read.
        case complete
        /// Some process could not be read for an unexpected reason. A hit still counts; a miss is unknown.
        case incomplete
        /// Nothing usable. Every answer is unknown.
        case failed
    }

    /// Device and inode of an open file.
    struct Identity: Hashable, Sendable {
        let device: UInt32
        let inode: UInt64
    }

    /// Every path that is, or contains, something a process holds: each held path and all its parents.
    private let heldPrefixes: Set<String>
    private let heldIdentities: Set<Identity>
    private let completeness: Completeness

    /// Creates a snapshot from known data. Used by `take` and by tests.
    init(heldPaths: [[String]], identities: Set<Identity>, completeness: Completeness) {
        var prefixes = Set<String>()
        for parts in heldPaths { Self.insertPrefixes(of: Self.normalize(parts), into: &prefixes) }
        self.heldPrefixes = prefixes
        self.heldIdentities = identities
        self.completeness = completeness
    }

    init(prefixes: Set<String>, identities: Set<Identity>, completeness: Completeness) {
        self.heldPrefixes = prefixes
        self.heldIdentities = identities
        self.completeness = completeness
    }

    /// A snapshot that knows nothing and answers `nil` to every question.
    static var failed: OpenFilesSnapshot {
        OpenFilesSnapshot(prefixes: [], identities: [], completeness: .failed)
    }

    /// Reads every process's open files once, with ``ProcessInspector``.
    ///
    /// - Parameter excludingPIDs: Processes to ignore. The default is this process, so the app's
    ///   own scan handles never block a clean.
    /// - Returns: The snapshot. If processes cannot be listed or too few can be read, it answers
    ///   `nil` to everything.
    public static func take(excludingPIDs: Set<Int32> = [getpid()]) async -> OpenFilesSnapshot {
        await ProcessInspector.captureOffPool(excluding: excludingPIDs)
    }

    /// `true` when a process had the item or something inside it open, `false` when none did,
    /// `nil` when the snapshot cannot say.
    public func hasOpenFiles(under url: URL) async -> Bool? {
        answer(for: url)
    }

    /// The answer, without the `async` wrapper.
    ///
    /// A path is compared by its real location (the folder it is in is resolved, the name is kept),
    /// because the system reports `/private/var/...` where callers may say `/var/...`.
    func answer(for url: URL) -> Bool? {
        if completeness == .failed { return nil }
        guard let parts = Self.realLocation(of: url), let info = try? GateSystem.lstatInfo(of: url) else {
            return nil
        }
        let wanted = Self.normalize(parts).joined(separator: "/")
        let identity = Identity(device: UInt32(bitPattern: info.st_dev), inode: UInt64(info.st_ino))
        if heldPrefixes.contains(wanted) || heldIdentities.contains(identity) { return true }
        return completeness == .complete ? false : nil
    }

    /// Components of the item's path with its folder resolved through symlinks and firmlinks.
    /// The last name is kept as given, so a symlink item is judged as the link, not its target.
    private static func realLocation(of url: URL) -> [String]? {
        guard let parts = PathParts.components(of: url), let name = parts.last else { return nil }
        guard let parent = try? GateSystem.realPath(of: url.deletingLastPathComponent()),
            let parentParts = PathParts.components(of: parent)
        else { return nil }
        return parentParts + [name]
    }

    // MARK: - Path keys

    /// Components in comparison form: case-folded, `/System/Volumes/Data` dropped.
    static func normalize(_ parts: [String]) -> [String] {
        let folded = parts.map(PathParts.fold)
        if folded.starts(with: ["system", "volumes", "data"]) { return Array(folded.dropFirst(3)) }
        return folded
    }

    /// Adds the path and every parent of it. Stops at the first parent already present,
    /// because its parents were added with it.
    static func insertPrefixes(of parts: [String], into set: inout Set<String>) {
        var count = parts.count
        while count > 0, set.insert(parts[0..<count].joined(separator: "/")).inserted { count -= 1 }
    }
}

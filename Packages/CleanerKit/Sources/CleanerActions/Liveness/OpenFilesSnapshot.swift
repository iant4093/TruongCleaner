import CleanerCore
import Darwin
import Foundation

/// One look at every process's open files, answered many times.
///
/// `ProcessOpenFilesProvider` scans every process on each call (about 120 ms). A clean asks about
/// hundreds of items, so `Cleaner` takes one snapshot per run and refreshes it now and then.
/// The snapshot records, for each process, its open files, current folder and root folder,
/// and answers `hasOpenFiles(under:)` from memory.
///
/// A snapshot that could not be taken, or that missed a process it failed to read, never answers
/// "nothing is open": the answer is `nil`, which the gate treats as "keep".
/// Processes the user may not inspect (other users', system daemons) cannot be seen and are skipped,
/// as in `ProcessOpenFilesProvider`. A file opened after the snapshot is not seen.
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

    private init(prefixes: Set<String>, identities: Set<Identity>, completeness: Completeness) {
        self.heldPrefixes = prefixes
        self.heldIdentities = identities
        self.completeness = completeness
    }

    /// A snapshot that knows nothing and answers `nil` to every question.
    static var failed: OpenFilesSnapshot {
        OpenFilesSnapshot(prefixes: [], identities: [], completeness: .failed)
    }

    /// Reads every process's open files once.
    ///
    /// - Parameter excludingPIDs: Processes to ignore. The default is this process, so the app's
    ///   own scan handles never block a clean.
    /// - Returns: The snapshot. If processes cannot be listed it answers `nil` to everything.
    @concurrent
    public static func take(excludingPIDs: Set<Int32> = [getpid()]) async -> OpenFilesSnapshot {
        guard let pids = ProcessOpenFilesProvider.allPIDs() else { return .failed }
        var prefixes = Set<String>()
        var identities = Set<Identity>()
        var incomplete = false
        for pid in pids where pid > 0 && !excludingPIDs.contains(pid) {
            if !collect(pid, prefixes: &prefixes, identities: &identities) { incomplete = true }
        }
        return OpenFilesSnapshot(
            prefixes: prefixes, identities: identities, completeness: incomplete ? .incomplete : .complete)
    }

    /// `true` when a process had the item or something inside it open, `false` when none did,
    /// `nil` when the snapshot cannot say.
    public func hasOpenFiles(under url: URL) async -> Bool? {
        if completeness == .failed { return nil }
        guard let parts = PathParts.components(of: url), let info = try? GateSystem.lstatInfo(of: url) else {
            return nil
        }
        let wanted = Self.normalize(parts).joined(separator: "/")
        let identity = Identity(device: UInt32(bitPattern: info.st_dev), inode: UInt64(info.st_ino))
        if heldPrefixes.contains(wanted) || heldIdentities.contains(identity) { return true }
        return completeness == .complete ? false : nil
    }

    // MARK: - Reading processes

    /// Adds one process's paths and file identities. Returns false when an unexpected failure
    /// means the process may have been missed.
    private static func collect(_ pid: Int32, prefixes: inout Set<String>, identities: inout Set<Identity>) -> Bool {
        var complete = true

        // Current and root folders.
        var folders = proc_vnodepathinfo()
        let folderSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        errno = 0
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &folders, folderSize) == folderSize {
            if let parts = pathParts(&folders.pvi_cdir.vip_path) { insertPrefixes(of: normalize(parts), into: &prefixes) }
            if let parts = pathParts(&folders.pvi_rdir.vip_path) { insertPrefixes(of: normalize(parts), into: &prefixes) }
        } else if !isBenign(errno) {
            complete = false
        }

        // Open files.
        errno = 0
        let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return complete && isBenign(errno) }
        let entrySize = MemoryLayout<proc_fdinfo>.size
        // Descriptors can be opened between the two calls, so leave room.
        let capacity = Int(listSize) / entrySize + 32
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        errno = 0
        let listed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(capacity * entrySize))
        guard listed > 0 else { return complete && isBenign(errno) }

        for descriptor in descriptors.prefix(Int(listed) / entrySize)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            errno = 0
            if proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size {
                let stat = info.pvip.vip_vi.vi_stat
                identities.insert(Identity(device: stat.vst_dev, inode: stat.vst_ino))
                if let parts = pathParts(&info.pvip.vip_path) { insertPrefixes(of: normalize(parts), into: &prefixes) }
            } else if !isBenign(errno) && errno != EBADF && errno != ENOENT {
                // EBADF/ENOENT: the descriptor closed in the meantime, so it is not open any more.
                complete = false
            }
        }
        return complete
    }

    /// Whether a failed `proc_pid*` call only means "nothing to see here": the process ended,
    /// belongs to someone else, or has nothing to report.
    private static func isBenign(_ code: Int32) -> Bool {
        code == 0 || code == ESRCH || code == EPERM || code == EACCES
    }

    /// Components of the NUL-terminated path in a C character array, or nil when it is empty.
    private static func pathParts<Buffer>(_ path: inout Buffer) -> [String]? {
        withUnsafeBytes(of: &path) { bytes in
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            guard end > 0 else { return nil }
            let text = String(decoding: bytes[0..<end], as: UTF8.self)
            return text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
    }

    // MARK: - Path keys

    /// Components in comparison form: case-folded, `/System/Volumes/Data` dropped.
    private static func normalize(_ parts: [String]) -> [String] {
        let folded = parts.map(PathParts.fold)
        if folded.starts(with: ["system", "volumes", "data"]) { return Array(folded.dropFirst(3)) }
        return folded
    }

    /// Adds the path and every parent of it. Stops at the first parent already present,
    /// because its parents were added with it.
    private static func insertPrefixes(of parts: [String], into set: inout Set<String>) {
        var count = parts.count
        while count > 0, set.insert(parts[0..<count].joined(separator: "/")).inserted { count -= 1 }
    }
}

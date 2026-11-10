import Darwin
import Foundation

/// Reads what every process has open. The only code that calls `proc_pidinfo` and `proc_pidfdinfo`.
///
/// For each process it records the current folder, the root folder and the path and
/// `(device, inode)` of every open file, using libproc. It builds an ``OpenFilesSnapshot``, and
/// both ``ProcessOpenFilesProvider`` (one fresh snapshot per question) and the snapshot a clean
/// reuses answer from that same data, so a file question and a folder question can never disagree
/// because they took different looks at the process table.
///
/// `proc_listpidspath` is not used. With no flags it matches only the exact file or folder named,
/// never files inside a folder; it takes about 200 ms per call; and in testing it sometimes
/// returned no process although the calling process held the file open.
///
/// What counts as "not a problem": `ESRCH` (the process ended, so it holds nothing) and `EPERM`
/// (the process is not ours, or the system hides the descriptor; no user-level tool can see it).
/// Everything else makes the snapshot incomplete, and an incomplete snapshot never answers `false`.
/// That includes an unexpected `errno`, a descriptor whose path cannot be read, and a snapshot
/// that reached too few processes.
///
/// A call that fails without setting `errno` is read again on a later pass, after the rest of the
/// table has been read. If it still gives nothing, the system is hiding that process's descriptors
/// without saying so (Xcode's `DTServiceHub` does this for as long as it runs; `lsof` shows
/// `err FD` for it too), and it is treated like `EPERM`. Treating it as a failure would make every
/// answer unknown for as long as such a process exists.
enum ProcessInspector {
    /// A snapshot that read fewer than this share of the current user's processes is not trusted.
    static let minimumCoverage = 0.5

    /// How many passes read a process that failed. Descriptors and processes come and go,
    /// so a later look usually succeeds.
    static let attempts = 3

    /// How reading one process ended.
    enum Outcome: Equatable {
        /// Folders and descriptors were read.
        case read
        /// The process ended while it was read, so it holds nothing.
        case gone
        /// The process is not ours.
        case hidden
        /// A call gave nothing and set no `errno`. Treated as a failure until it has been read again.
        case silent
        /// An unexpected failure: this process may hold something that was missed.
        case failed
    }

    /// Where captures run: at most two at a time, on dispatch threads of their own.
    ///
    /// A capture makes about 10,000 system calls over 100 ms or more. On the Swift cooperative
    /// pool (one thread per core, three on a small CI runner) a few of them in a row would keep
    /// every other task waiting for a thread. The cap keeps a burst of questions from creating a
    /// thread per question.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "TruongCleaner.ProcessInspector"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Takes a snapshot off the cooperative pool and suspends until it is ready.
    static func captureOffPool(excluding excluded: Set<Int32>) async -> OpenFilesSnapshot {
        await withCheckedContinuation { continuation in
            queue.addOperation { continuation.resume(returning: capture(excluding: excluded)) }
        }
    }

    /// Takes a snapshot of every process except `excluded`. Blocks the calling thread for the
    /// whole read; async callers use ``captureOffPool(excluding:)``.
    ///
    /// - Parameters:
    ///   - excluded: Processes to ignore.
    ///   - listProcesses: Gives the process IDs to read. Tests replace it; the default lists them all.
    /// - Returns: The snapshot. If the process list cannot be read, or fewer than half of the
    ///   current user's processes could be read, it answers `nil` to every question.
    static func capture(
        excluding excluded: Set<Int32>, listProcesses: () -> [Int32]? = { allPIDs() }
    ) -> OpenFilesSnapshot {
        guard let listed = listProcesses() else { return .failed }
        let pids = listed.filter { $0 > 0 && !excluded.contains($0) }
        guard !pids.isEmpty else { return .failed }

        // Only the user's own processes can hold the user's files open without root, so only they
        // count toward coverage. A process whose owner cannot be read counts as the user's.
        let mine = Set(pids.filter { ProcessTable.belongsToCurrentUser($0) != false })
        guard !mine.isEmpty else { return .failed }

        var accumulator = Accumulator()
        var readable = 0
        // A process that fails is read again after the others, so a process in the middle of
        // starting or ending is given time to settle without this code sleeping.
        var pending = pids
        var unsettled: [Int32: Outcome] = [:]
        for _ in 0..<attempts {
            var again: [Int32] = []
            for pid in pending {
                switch inspect(pid, into: &accumulator) {
                case .read:
                    if mine.contains(pid) { readable += 1 }
                    unsettled[pid] = nil
                case .gone, .hidden:
                    unsettled[pid] = nil
                case .silent:
                    unsettled[pid] = .silent
                    again.append(pid)
                case .failed:
                    unsettled[pid] = .failed
                    again.append(pid)
                }
            }
            pending = again
            if pending.isEmpty { break }
        }
        let incomplete = unsettled.values.contains(.failed)
        // Processes that are hidden or gone cannot vouch for anything. If most of the user's own
        // processes were out of reach, "nothing is open" would mean "nothing I could see".
        guard Double(readable) >= minimumCoverage * Double(mine.count) else { return .failed }
        return OpenFilesSnapshot(
            prefixes: accumulator.prefixes, identities: accumulator.identities,
            completeness: incomplete ? .incomplete : .complete)
    }

    /// All process IDs, or nil when the list cannot be read.
    static func allPIDs() -> [Int32]? {
        let slot = MemoryLayout<Int32>.size
        var capacity = 0
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return nil }
        capacity = Int(needed) / slot * 2 + 64
        // Processes can start between the two calls; grow until the buffer is clearly big enough.
        for _ in 0..<4 {
            var buffer = [Int32](repeating: 0, count: capacity)
            let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer, Int32(capacity * slot))
            guard written > 0 else { return nil }
            let count = Int(written) / slot
            if count < capacity { return Array(buffer.prefix(count)) }
            capacity *= 2
        }
        return nil
    }

    // MARK: - Collected data

    /// What has been read so far.
    private struct Accumulator {
        /// Every held path and all its parents, in comparison form.
        var prefixes = Set<String>()
        var identities = Set<OpenFilesSnapshot.Identity>()

        mutating func add(path parts: [String]) {
            OpenFilesSnapshot.insertPrefixes(of: OpenFilesSnapshot.normalize(parts), into: &prefixes)
        }
    }

    // MARK: - One process

    /// What an unsuccessful libproc call means.
    private enum Failure {
        case gone
        case hidden
        case silent
        case unexpected
    }

    /// Classifies a failed call. `errno` 0 is unexpected: the call said "no" without saying why.
    private static func classify(_ code: Int32) -> Failure {
        switch code {
        case ESRCH: .gone
        case EPERM: .hidden
        case 0: .silent
        default: .unexpected
        }
    }

    /// Reads one process's current folder, root folder and open files.
    private static func inspect(_ pid: Int32, into accumulator: inout Accumulator) -> Outcome {
        // Current and root folders.
        var folders = proc_vnodepathinfo()
        let folderSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        errno = 0
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &folders, folderSize) == folderSize {
            if let parts = pathParts(&folders.pvi_cdir.vip_path) { accumulator.add(path: parts) }
            if let parts = pathParts(&folders.pvi_rdir.vip_path) { accumulator.add(path: parts) }
            let stat = folders.pvi_cdir.vip_vi.vi_stat
            accumulator.identities.insert(.init(device: stat.vst_dev, inode: stat.vst_ino))
        } else {
            switch classify(errno) {
            case .gone: return .gone
            case .hidden: return .hidden
            case .silent: return .silent
            case .unexpected: return .failed
            }
        }

        // Open files.
        guard let descriptors = listDescriptors(of: pid) else {
            switch classify(errno) {
            case .gone: return .gone
            case .hidden: return .hidden
            case .silent: return .silent
            case .unexpected: return .failed
            }
        }
        var outcome = Outcome.read
        for descriptor in descriptors
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            errno = 0
            if proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size {
                let stat = info.pvip.vip_vi.vi_stat
                accumulator.identities.insert(.init(device: stat.vst_dev, inode: stat.vst_ino))
                if let parts = pathParts(&info.pvip.vip_path) {
                    accumulator.add(path: parts)
                } else if stat.vst_nlink > 0 {
                    // The file is linked but the system gave no name for it: a folder question
                    // cannot be answered for this process. An unlinked file lies in no folder.
                    outcome = .failed
                }
            } else {
                switch errno {
                case ESRCH: return .gone
                case EPERM: continue  // The system hides this descriptor.
                case EBADF: continue  // The descriptor closed after it was listed.
                default: outcome = .failed
                }
            }
        }
        return outcome
    }

    /// The vnode descriptors of a process, or nil with `errno` set to the reason.
    ///
    /// A call that returns nothing without an error is reported as `errno` 0.
    private static func listDescriptors(of pid: Int32) -> [proc_fdinfo]? {
        let entrySize = MemoryLayout<proc_fdinfo>.size
        errno = 0
        let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return nil }
        // Descriptors can be opened between the two calls, so leave room, and grow if it was not enough.
        var capacity = Int(listSize) / entrySize + 32
        for _ in 0..<4 {
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            errno = 0
            let listed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(capacity * entrySize))
            guard listed > 0 else { return nil }
            let count = Int(listed) / entrySize
            if count < capacity { return Array(descriptors.prefix(count)) }
            capacity *= 2
        }
        errno = 0
        return nil
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
}

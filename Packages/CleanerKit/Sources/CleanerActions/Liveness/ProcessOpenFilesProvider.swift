import CleanerCore
import Darwin
import Foundation

/// Finds processes that have an item, or a file inside it, open.
///
/// For every process it reads the open files, the current folder and the root folder with
/// `proc_pidinfo` and `proc_pidfdinfo` (libproc), and reports a hit when a path is the item or
/// lies below it, or when an open file is the item itself by `(device, inode)` (so a hard link
/// or a differently spelled path is still found).
///
/// `proc_listpidspath` is not used. With no flags it matches only the exact file or folder named,
/// never files inside a folder; it takes about 200 ms per call; and in testing it sometimes
/// returned no process although the calling process held the file open. A missing answer there
/// would read as "nothing is open", which this check must never do.
///
/// Processes the user may not inspect (other users', system daemons) cannot be seen by any
/// user-level tool and are skipped. Any other failure makes the answer nil, which the gate treats
/// as "keep".
public struct ProcessOpenFilesProvider: OpenFilesProvider {
    private let excludedPIDs: Set<Int32>

    /// Creates a provider.
    ///
    /// - Parameter excludingPIDs: Processes to ignore. The default is this process, so the
    ///   app's own scan handles never block a clean.
    public init(excludingPIDs: Set<Int32> = [getpid()]) {
        self.excludedPIDs = excludingPIDs
    }

    /// `true` when a process has the item or a file inside it open, `false` when none does,
    /// `nil` when this could not be determined.
    @concurrent
    public func hasOpenFiles(under url: URL) async -> Bool? {
        Self.check(url, excluding: excludedPIDs)
    }

    // MARK: - Implementation

    /// What looking at one process found.
    private enum Inspection {
        case holdsPath
        case doesNot
        /// An unexpected failure: the answer is unknown.
        case failed
    }

    static func check(_ url: URL, excluding excluded: Set<Int32>) -> Bool? {
        guard let wanted = comparable(url) else { return nil }
        let info: stat
        do {
            info = try GateSystem.lstatInfo(of: url)
        } catch {
            return nil
        }
        let item = ItemIdentity(device: UInt32(bitPattern: info.st_dev), inode: UInt64(info.st_ino))
        guard let pids = allPIDs() else { return nil }

        var unknown = false
        for pid in pids where pid > 0 && !excluded.contains(pid) {
            switch inspect(pid, wanted: wanted, item: item) {
            case .holdsPath: return true
            case .doesNot: continue
            case .failed: unknown = true
            }
        }
        // A hit anywhere wins; otherwise one unreadable process makes the answer unknown.
        return unknown ? nil : false
    }

    /// Device and inode of the item, to recognise it behind another name.
    private struct ItemIdentity {
        let device: UInt32
        let inode: UInt64
    }

    /// All process IDs.
    static func allPIDs() -> [Int32]? {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return nil }
        let capacity = Int(needed) / MemoryLayout<Int32>.size * 2 + 64
        var buffer = [Int32](repeating: 0, count: capacity)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer, Int32(capacity * MemoryLayout<Int32>.size))
        guard written > 0 else { return nil }
        return Array(buffer.prefix(Int(written) / MemoryLayout<Int32>.size))
    }

    /// Whether a failed `proc_pid*` call only means "nothing to see here": the process ended,
    /// belongs to someone else, or has nothing to report.
    private static func isBenign(_ code: Int32) -> Bool {
        code == 0 || code == ESRCH || code == EPERM || code == EACCES
    }

    /// Checks one process's current folder, root folder and open files against the item.
    private static func inspect(_ pid: Int32, wanted: [String], item: ItemIdentity) -> Inspection {
        // Current and root folders.
        var folders = proc_vnodepathinfo()
        let folderSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        errno = 0
        let folderResult = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &folders, folderSize)
        if folderResult == folderSize {
            if isUnder(&folders.pvi_cdir.vip_path, wanted) || isUnder(&folders.pvi_rdir.vip_path, wanted) {
                return .holdsPath
            }
        } else if !isBenign(errno) {
            return .failed
        }

        // Open files.
        errno = 0
        let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return isBenign(errno) ? .doesNot : .failed }
        let entrySize = MemoryLayout<proc_fdinfo>.size
        // Descriptors can be opened between the two calls, so leave room.
        let capacity = Int(listSize) / entrySize + 32
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        errno = 0
        let listed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(capacity * entrySize))
        guard listed > 0 else { return isBenign(errno) ? .doesNot : .failed }

        for descriptor in descriptors.prefix(Int(listed) / entrySize)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            errno = 0
            let got = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size)
            if got == size {
                let stat = info.pvip.vip_vi.vi_stat
                if stat.vst_dev == item.device && stat.vst_ino == item.inode { return .holdsPath }
                if isUnder(&info.pvip.vip_path, wanted) { return .holdsPath }
            } else if !isBenign(errno) && errno != EBADF && errno != ENOENT {
                // EBADF/ENOENT: the descriptor closed in the meantime, so it is not open any more.
                return .failed
            }
        }
        return .doesNot
    }

    /// Whether the NUL-terminated path in a C character array is at or below `wanted`.
    private static func isUnder<Buffer>(_ path: inout Buffer, _ wanted: [String]) -> Bool {
        let parts: [String]? = withUnsafeBytes(of: &path) { bytes in
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            guard end > 0 else { return nil }
            let text = String(decoding: bytes[0..<end], as: UTF8.self)
            return normalize(text.split(separator: "/", omittingEmptySubsequences: true).map(String.init))
        }
        guard let parts else { return false }
        return parts.starts(with: wanted)
    }

    /// Components of `url` in comparison form: case-folded, `/System/Volumes/Data` dropped.
    private static func comparable(_ url: URL) -> [String]? {
        PathParts.components(of: url).map(normalize)
    }

    private static func normalize(_ parts: [String]) -> [String] {
        let folded = parts.map(PathParts.fold)
        if folded.starts(with: ["system", "volumes", "data"]) { return Array(folded.dropFirst(3)) }
        return folded
    }
}

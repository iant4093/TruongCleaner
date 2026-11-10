import Darwin
import Foundation

/// Finds files that were changed after they were downloaded.
///
/// Mail keeps a copy of every attachment the user opens in `Mail Downloads`. When the user edits and
/// saves such a copy, the saved file stays there and may be the only copy of the edit. A file that was
/// only downloaded has `mtime <= birthtime` (give or take the time the download took). A file with a
/// later `mtime` was changed since, so the whole item is kept.
enum DownloadEdits {
    /// How much later than its creation a file may have been written and still count as untouched.
    static let tolerance: TimeInterval = 5

    /// Most entries the check looks at. A bigger item is kept.
    static let entryLimit = 50_000

    /// Deepest folder level the check follows. A deeper item is kept.
    static let depthLimit = 32

    /// Longest the check may take.
    static let timeLimit: Duration = .seconds(5)

    /// Whether any file in the item, or the item itself if it is a file, has `mtime > birthtime + tolerance`.
    ///
    /// Symbolic links are not followed and are not judged. Anything that cannot be read, a limit that is
    /// reached, or an entry that is neither a file, a folder nor a link, throws, and the caller keeps the item.
    static func isEditedAfterDownload(_ item: URL) throws -> Bool {
        let info = try GateSystem.lstatInfo(of: item)
        if GateSystem.isSymlink(info) { throw SysError(call: "lstat", code: EFTYPE) }
        if !GateSystem.isDirectory(info) { return try judge(info) }

        let fd = try GateSystem.withPath(item) { path -> Int32 in
            let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw SysError(call: "open", code: errno) }
            return descriptor
        }
        var budget = Budget(deadline: ContinuousClock.now + timeLimit)
        return try walk(directory: fd, depth: 1, budget: &budget)
    }

    private struct Budget {
        var entries = 0
        let deadline: ContinuousClock.Instant
    }

    /// Walks the folder behind `directory` (an open descriptor that this function closes).
    private static func walk(directory fd: Int32, depth: Int, budget: inout Budget) throws -> Bool {
        guard depth <= depthLimit, let stream = fdopendir(fd) else {
            let code = errno
            close(fd)
            throw SysError(call: depth > depthLimit ? "depth" : "fdopendir", code: depth > depthLimit ? EFBIG : code)
        }
        defer { closedir(stream) }  // Closes `fd` as well.
        var subfolders: [[CChar]] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw SysError(call: "readdir", code: errno) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    Array(UnsafeBufferPointer(start: $0, count: Int(entry.pointee.d_namlen) + 1))
                }
            }
            if isDotEntry(name) { continue }
            budget.entries += 1
            guard budget.entries <= entryLimit, ContinuousClock.now < budget.deadline else {
                throw SysError(call: "walk", code: EFBIG)
            }
            var info = stat()
            guard fstatat(dirfd(stream), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SysError(call: "fstatat", code: errno)
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                if try judge(info) { return true }
            case S_IFDIR:
                subfolders.append(name)
            case S_IFLNK:
                continue
            default:
                throw SysError(call: "fstatat", code: EFTYPE)
            }
        }
        for name in subfolders {
            let child = openat(dirfd(stream), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw SysError(call: "openat", code: errno) }
            if try walk(directory: child, depth: depth + 1, budget: &budget) { return true }
        }
        return false
    }

    private static func isDotEntry(_ name: [CChar]) -> Bool {
        (name.count == 2 && name[0] == 0x2E) || (name.count == 3 && name[0] == 0x2E && name[1] == 0x2E)
    }

    /// Whether one regular file was modified more than `tolerance` after it was created.
    private static func judge(_ info: stat) throws -> Bool {
        guard info.st_mode & S_IFMT == S_IFREG else { return false }
        let birth = seconds(info.st_birthtimespec)
        let modified = seconds(info.st_mtimespec)
        // A creation date of zero means the volume did not record one. Unknown means keep.
        guard info.st_birthtimespec.tv_sec > 0 else { throw SysError(call: "lstat", code: EIO) }
        return modified > birth + tolerance
    }

    private static func seconds(_ time: timespec) -> TimeInterval {
        TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) * 1e-9
    }
}

import Darwin
import Foundation

/// A failed system call. Never contains a path, so it is safe to put in history and logs.
struct SysError: Error, CustomStringConvertible {
    let call: String
    let code: Int32

    /// The thing the call looked at is gone (or a parent is no longer a folder).
    var isMissing: Bool { code == ENOENT || code == ENOTDIR }

    var description: String { "\(call): \(String(cString: strerror(code))) (errno \(code))" }
}

/// Identity of a file system entry as the scanner records it.
struct EntryIdentity: Equatable {
    var fsid: UInt64
    var fileID: UInt64
}

/// One name in a folder listing, with its modification date when it could be read.
struct DirectoryChild {
    var name: [UInt8]
    var modified: Date?
}

/// Thin wrappers over the system calls the gate needs. All of them look at the entry itself
/// and never follow a symbolic link in the last component.
enum GateSystem {
    // MARK: Flags

    /// Flags that forbid removing an entry: system-restricted, no-unlink, immutable, append-only.
    static let protectingFlags: UInt32 =
        UInt32(SF_RESTRICTED) | UInt32(SF_NOUNLINK)
        | UInt32(SF_IMMUTABLE) | UInt32(UF_IMMUTABLE)
        | UInt32(SF_APPEND) | UInt32(UF_APPEND)

    /// Whether any flag in `flags` forbids removal.
    static func isMacOSProtected(flags: UInt32) -> Bool {
        flags & protectingFlags != 0
    }

    // MARK: Paths

    /// Runs `body` with the file system representation of `url`.
    static func withPath<Result>(
        _ url: URL, _ body: (UnsafePointer<CChar>) throws -> Result
    ) throws -> Result {
        try url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { throw SysError(call: "path", code: EINVAL) }
            return try body(pointer)
        }
    }

    /// The real path of a folder or file, with every symlink resolved.
    static func realPath(of url: URL) throws -> URL {
        try withPath(url) { path in
            guard let resolved = realpath(path, nil) else { throw SysError(call: "realpath", code: errno) }
            defer { free(resolved) }
            return URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: true, relativeTo: nil)
        }
    }

    /// `lstat` of the entry itself.
    static func lstatInfo(of url: URL) throws -> stat {
        try withPath(url) { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { throw SysError(call: "lstat", code: errno) }
            return info
        }
    }

    /// Whether the entry itself is a symbolic link.
    static func isSymlink(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFLNK }

    /// Whether the entry is a folder (not a link to one).
    static func isDirectory(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFDIR }

    /// Modification date from an `lstat` result.
    static func modificationDate(_ info: stat) -> Date {
        Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) * 1e-9)
    }

    // MARK: Identity

    /// `(fsid, fileID)` of the entry itself, read with `getattrlist` and `FSOPT_NOFOLLOW`.
    /// `fsid` is packed like the scanner does: `val[0] << 32 | val[1]`.
    static func identity(of url: URL) throws -> EntryIdentity {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_FSID) | attrgroup_t(ATTR_CMN_FILEID)
        // Reply: u32 length, fsid (2 x i32), file ID (u64). Packed on 4-byte boundaries.
        var reply = [UInt8](repeating: 0, count: 64)
        let result = try withPath(url) { path in
            reply.withUnsafeMutableBytes { bytes in
                getattrlist(path, &list, bytes.baseAddress, bytes.count, UInt32(FSOPT_NOFOLLOW))
            }
        }
        guard result == 0 else { throw SysError(call: "getattrlist", code: errno) }
        return try reply.withUnsafeBytes { bytes in
            guard bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self) >= 20 else {
                throw SysError(call: "getattrlist", code: EIO)
            }
            let first = bytes.loadUnaligned(fromByteOffset: 4, as: Int32.self)
            let second = bytes.loadUnaligned(fromByteOffset: 8, as: Int32.self)
            let fileID = bytes.loadUnaligned(fromByteOffset: 12, as: UInt64.self)
            return EntryIdentity(
                fsid: UInt64(UInt32(bitPattern: first)) << 32 | UInt64(UInt32(bitPattern: second)),
                fileID: fileID)
        }
    }

    // MARK: Listing

    /// Names and modification dates of a folder's children, read with `getattrlistbulk`.
    ///
    /// A child whose date could not be read is returned with `modified == nil`.
    /// The folder is opened without following a link in its last component.
    static func children(of directory: URL) throws -> [DirectoryChild] {
        let fd = try withPath(directory) { path -> Int32 in
            let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw SysError(call: "open", code: errno) }
            return descriptor
        }
        defer { close(fd) }

        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_MODTIME)

        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var result: [DirectoryChild] = []
        while true {
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw SysError(call: "getattrlistbulk", code: errno)
            }
            if count == 0 { break }
            var start = 0
            for _ in 0..<Int(count) {
                guard start + 4 <= bufferSize else { throw SysError(call: "getattrlistbulk", code: EIO) }
                let length = Int(buffer.loadUnaligned(fromByteOffset: start, as: UInt32.self))
                // 4 (length) + 20 (returned attribute set) is the smallest valid entry.
                guard length >= 24, start + length <= bufferSize else {
                    throw SysError(call: "getattrlistbulk", code: EIO)
                }
                if let child = parseChild(UnsafeRawBufferPointer(start: buffer + start, count: length)) {
                    result.append(child)
                }
                start += length
            }
        }
        return result
    }

    /// Parses one packed entry: length, returned set (5 words), [error], name reference, [modification time].
    private static func parseChild(_ entry: UnsafeRawBufferPointer) -> DirectoryChild? {
        let returned = entry.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        var offset = 24
        if returned & attrgroup_t(ATTR_CMN_ERROR) != 0 { offset += 4 }
        guard returned & attrgroup_t(ATTR_CMN_NAME) != 0, offset + 8 <= entry.count else { return nil }
        let referenceStart = offset
        let nameOffset = Int(entry.loadUnaligned(fromByteOffset: offset, as: Int32.self))
        let nameLength = Int(entry.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
        offset += 8
        let nameStart = referenceStart + nameOffset
        guard nameLength >= 2, nameStart >= 0, nameStart + nameLength <= entry.count else { return nil }
        let name = Array(entry[nameStart..<(nameStart + nameLength - 1)])

        var modified: Date?
        let failed = returned & attrgroup_t(ATTR_CMN_ERROR) != 0
        if !failed, returned & attrgroup_t(ATTR_CMN_MODTIME) != 0, offset + 16 <= entry.count {
            let seconds = entry.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            let nanos = entry.loadUnaligned(fromByteOffset: offset + 8, as: Int64.self)
            modified = Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) * 1e-9)
        }
        return DirectoryChild(name: name, modified: modified)
    }
}

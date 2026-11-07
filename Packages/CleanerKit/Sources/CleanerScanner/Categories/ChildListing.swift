import Darwin
import Foundation

/// One direct child of a folder, read without following links.
struct ChildEntry: Sendable {
    /// Name, decoded for matching. Not used to build paths.
    let name: String
    /// Exact path bytes, NUL-terminated.
    let path: [CChar]
    /// True for a real folder. A symlink to a folder is not one.
    let isDirectory: Bool
    /// Allocated bytes from `lstat` (`st_blocks`). Only used for entries that are not folders.
    let allocatedBytes: Int64
    let device: Int32
    let inode: UInt64

    var url: URL { makeURL(fromPath: path, isDirectory: isDirectory) }
}

/// Why a folder could not be listed.
struct ListingFailure: Error, Sendable {
    let code: Int32

    var isDenied: Bool { code == EPERM || code == EACCES }
    var isMissing: Bool { code == ENOENT || code == ENOTDIR }
}

/// A folder's direct children.
struct ChildListing: Sendable {
    var entries: [ChildEntry]
    /// Names of children macOS would not let us examine (`EPERM`/`EACCES`). Their size is unknown.
    var deniedNames: [String]
    /// Children that could not be examined for another reason (a vanished child is not counted).
    var unreadable: Int

    /// Lists `directory` with `opendir` and examines each child with `lstat`. Reads only.
    static func read(_ directory: URL) -> Result<ChildListing, ListingFailure> {
        let base = directory.withUnsafeFileSystemRepresentation { pointer -> [CChar]? in
            guard let pointer else { return nil }
            return Array(UnsafeBufferPointer(start: pointer, count: strlen(pointer)))
        }
        guard let base else { return .failure(ListingFailure(code: EINVAL)) }
        guard let handle = opendir(base + [0]) else { return .failure(ListingFailure(code: errno)) }
        defer { closedir(handle) }

        var listing = ChildListing(entries: [], deniedNames: [], unreadable: 0)
        let needsSeparator = base.last != CChar(UInt8(ascii: "/"))
        while let item = readdir(handle) {
            let length = Int(item.pointee.d_namlen)
            let name = withUnsafeBytes(of: &item.pointee.d_name) { raw in
                raw.prefix(length).map { CChar(bitPattern: $0) }
            }
            if name == [0x2E] || name == [0x2E, 0x2E] { continue }

            var path = base
            if needsSeparator { path.append(CChar(UInt8(ascii: "/"))) }
            path.append(contentsOf: name)
            path.append(0)

            var info = stat()
            guard lstat(path, &info) == 0 else {
                let code = errno
                if code == EPERM || code == EACCES {
                    listing.deniedNames.append(String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                } else if code != ENOENT {
                    listing.unreadable += 1
                }
                continue
            }
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR
            listing.entries.append(
                ChildEntry(
                    name: String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                    path: path,
                    isDirectory: isDirectory,
                    allocatedBytes: isDirectory ? 0 : Int64(info.st_blocks) * 512,
                    device: info.st_dev,
                    inode: UInt64(info.st_ino)))
        }
        return .success(listing)
    }

    /// Device and inode of `url` itself, following a symlink. `nil` if it cannot be read.
    static func identity(of url: URL) -> (device: Int32, inode: UInt64)? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return stat(pointer, &info)
        }
        return result == 0 ? (info.st_dev, UInt64(info.st_ino)) : nil
    }
}

import Darwin
import Foundation

/// One direct child of a folder, examined without following links.
struct FolderEntry: Sendable {
    enum Kind: Sendable {
        case directory
        case file
        case symlink
        case other
    }

    /// The name, or nil when its bytes are not valid UTF-8. Such an entry is never matched or offered.
    let name: String?
    /// Exact path bytes, NUL-terminated.
    let path: [CChar]
    let kind: Kind
    /// `st_flags` from `lstat`.
    let flags: UInt32
    /// Allocated bytes from `lstat`. Meaningful for files and links only.
    let allocatedBytes: Int64

    var url: URL { makeURL(fromPath: path, isDirectory: kind == .directory) }
}

/// A folder's direct children.
struct FolderListing: Sendable {
    var entries: [FolderEntry]
    /// Children that macOS would not let us examine (`EPERM`/`EACCES`).
    var denied = 0
    /// Children that could not be examined for another reason (vanished ones are not counted).
    var unreadable = 0

    /// True when every child was examined.
    var isComplete: Bool { denied == 0 && unreadable == 0 }
}

/// Lists one folder. Reads only, and never follows a symbolic link, not even in the folder's own name.
enum FolderReader {
    /// Most children examined in one folder. A longer folder is reported as unreadable, not truncated.
    static let entryLimit = 20_000

    static func read(_ folder: URL) -> Result<FolderListing, ListingFailure> {
        let base = folder.withUnsafeFileSystemRepresentation { pointer -> [CChar]? in
            guard let pointer else { return nil }
            return Array(UnsafeBufferPointer(start: pointer, count: strlen(pointer)))
        }
        guard let base else { return .failure(ListingFailure(code: EINVAL)) }
        let descriptor = open(base + [0], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            // A symbolic link in the folder's own name is refused (`ELOOP`); report it as not there.
            return .failure(ListingFailure(code: errno == ELOOP ? ENOENT : errno))
        }
        guard let handle = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            return .failure(ListingFailure(code: code))
        }
        defer { closedir(handle) }

        var listing = FolderListing(entries: [])
        let slash = CChar(UInt8(ascii: "/"))
        while let item = readdir(handle) {
            let length = Int(item.pointee.d_namlen)
            let name = withUnsafeBytes(of: &item.pointee.d_name) { raw in
                Array(raw.prefix(length))
            }
            if name == [0x2E] || name == [0x2E, 0x2E] { continue }
            if listing.entries.count + listing.unreadable + listing.denied >= entryLimit {
                listing.unreadable += 1
                break
            }

            var path = base
            if path.last != slash { path.append(slash) }
            path.append(contentsOf: name.map { CChar(bitPattern: $0) })
            path.append(0)

            var info = stat()
            guard lstat(path, &info) == 0 else {
                let code = errno
                if code == EPERM || code == EACCES {
                    listing.denied += 1
                } else if code != ENOENT {
                    listing.unreadable += 1
                }
                continue
            }
            let kind: FolderEntry.Kind
            switch info.st_mode & S_IFMT {
            case S_IFDIR: kind = .directory
            case S_IFREG: kind = .file
            case S_IFLNK: kind = .symlink
            default: kind = .other
            }
            // `String(validating:)` returns nil for bytes that are not UTF-8.
            let text = String(validating: name, as: UTF8.self)
            if text == nil { listing.unreadable += 1 }
            listing.entries.append(
                FolderEntry(
                    name: text, path: path, kind: kind, flags: info.st_flags,
                    allocatedBytes: Int64(info.st_blocks) * 512))
        }
        return .success(listing)
    }
}

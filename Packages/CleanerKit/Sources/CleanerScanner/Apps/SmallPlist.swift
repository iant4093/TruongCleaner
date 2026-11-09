import Darwin
import Foundation

/// Reads a small property list without following a symbolic link and without trusting its size.
enum SmallPlist {
    /// Largest plist the uninstaller reads for a container record or a launch job.
    static let limit = 256 * 1024

    enum Failure: Error, Equatable {
        /// There is no such file.
        case missing
        /// The file is bigger than the limit.
        case tooLarge
        /// The path is a link, a folder or another kind of entry.
        case notAFile
        /// The file could not be opened or read.
        case unreadable
        /// The bytes are not a property list with a dictionary at the top.
        case malformed
    }

    /// The top-level dictionary of the plist at `url`.
    static func read(at url: URL, limit: Int = SmallPlist.limit) -> Result<[String: Any], Failure> {
        let path = url.withUnsafeFileSystemRepresentation { pointer -> [CChar]? in
            guard let pointer else { return nil }
            return Array(UnsafeBufferPointer(start: pointer, count: strlen(pointer) + 1))
        }
        guard let path else { return .failure(.unreadable) }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .failure(.missing)
            case ELOOP: return .failure(.notAFile)
            default: return .failure(.unreadable)
            }
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .failure(.unreadable) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.notAFile) }
        guard info.st_size >= 0, info.st_size <= limit else { return .failure(.tooLarge) }

        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var filled = 0
        while filled < bytes.count {
            let count = bytes[filled...].withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(.unreadable)
            }
            if count == 0 { break }
            filled += count
        }
        // A file that shrank while we read it is not trusted.
        guard filled == bytes.count else { return .failure(.unreadable) }

        guard
            let object = try? PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil),
            let dictionary = object as? [String: Any]
        else { return .failure(.malformed) }
        return .success(dictionary)
    }
}

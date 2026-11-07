import Darwin
import Foundation

/// A cheap guess of how much work a root is, so the engine can start the big ones first.
enum RootHint {
    /// Counting stops here. A folder with this many entries is already "big".
    static let cap = 50_000

    /// Number of entries directly inside `directory`, up to `cap`. 0 when it cannot be read.
    ///
    /// Reads names only (no `stat` per entry), never follows a symbolic link and never throws: a hint
    /// only changes the order in which roots start, not what they find.
    static func entryCount(of directory: URL) -> Int {
        directory.withUnsafeFileSystemRepresentation { pointer -> Int in
            guard let pointer else { return 0 }
            let descriptor = open(pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { return 0 }
            guard let handle = fdopendir(descriptor) else {
                close(descriptor)
                return 0
            }
            defer { closedir(handle) }
            var count = 0
            while readdir(handle) != nil {
                count += 1
                if count >= cap { break }
            }
            return count
        }
    }
}

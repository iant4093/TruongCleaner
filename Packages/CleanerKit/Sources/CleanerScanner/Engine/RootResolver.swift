import CleanerCore
import Darwin
import Foundation

/// Concrete folders a rule root stands for, plus what could not be resolved.
struct ResolvedRoots: Sendable {
    /// Real folders (not symbolic links) to walk, in name order.
    var roots: [URL] = []
    /// Folders macOS refused to open.
    var needsAccess: [URL] = []
    /// A root that does not exist, or is not a real folder.
    var missing: [URL] = []
    /// True when something was left out for a reason other than "missing" or "denied".
    var incomplete = false
}

/// Turns an `ExpandedRoot` into folders that exist, without following symbolic links.
///
/// - The trusted base (the home folder, a Darwin directory or `/`) is resolved with `realpath`, because
///   the caller gave it to us. Every component below it, literal or matched by `*`, is checked with
///   `lstat`. A symbolic link or file anywhere below the base means that root is skipped, so a rule never
///   reaches a folder through a symlinked ancestor and the home-relative protected list always applies.
/// - Components after a `*` are listed one level at a time. Only real folders are kept.
/// - Each `*` level keeps at most `maxMatchesPerWildcard` folders, in name order.
/// - A literal component that is missing under a matched folder is not reported: that folder simply does
///   not match. Only a missing `base` goes to `missing`.
enum RootResolver {
    /// Most folders one `*` level may produce.
    static let maxMatchesPerWildcard = 2_000

    /// The folder a `RootSpec.Base` stands for, or nil when the environment does not know it.
    static func trustedBase(for base: RootSpec.Base, in environment: Environment) -> URL? {
        switch base {
        case .home: environment.home
        case .absolute: URL(filePath: "/", directoryHint: .isDirectory)
        case .darwinUserCache: environment.darwinUserCache
        case .darwinUserTemp: environment.darwinUserTemp
        }
    }

    /// - Parameters:
    ///   - expanded: The root to resolve.
    ///   - trusted: The base `expanded.base` was built from. The only place a symbolic link is resolved.
    static func resolve(_ expanded: ExpandedRoot, trusted: URL) -> ResolvedRoots {
        var resolved = ResolvedRoots()
        var base: URL
        switch FolderProbe.realPath(of: trusted) {
        case .success(let url):
            base = url
        case .failure(let failure):
            record(failure, at: expanded.base, in: &resolved)
            return resolved
        }

        // Literal components between the trusted base and the first `*`.
        let trustedCount = trusted.pathComponents.count
        let literals = expanded.base.pathComponents.dropFirst(trustedCount)
        for literal in literals {
            let next = base.appending(path: literal, directoryHint: .isDirectory)
            switch FolderProbe.kind(of: next) {
            case .folder:
                base = next
            case .other:
                resolved.missing.append(expanded.base)
                return resolved
            case .failure(let code) where code == EPERM || code == EACCES:
                resolved.needsAccess.append(next)
                return resolved
            case .failure(let code) where code == ENOENT || code == ENOTDIR:
                resolved.missing.append(expanded.base)
                return resolved
            case .failure:
                resolved.incomplete = true
                return resolved
            }
        }

        var current = [base]
        for component in expanded.pattern {
            if component.contains("*") {
                let pattern = GlobPattern(component)
                var next: [URL] = []
                var truncated = false
                for folder in current {
                    switch FolderProbe.childFolders(of: folder) {
                    case .failure(let failure):
                        record(failure, at: folder, in: &resolved)
                    case .success(let names):
                        for name in names where pattern.matches([fold(name)]) {
                            next.append(folder.appending(path: name, directoryHint: .isDirectory))
                        }
                    }
                }
                if next.count > maxMatchesPerWildcard {
                    next = Array(next.sorted { $0.plainPath < $1.plainPath }.prefix(maxMatchesPerWildcard))
                    truncated = true
                }
                if truncated { resolved.incomplete = true }
                current = next
            } else {
                var next: [URL] = []
                for folder in current {
                    let child = folder.appending(path: component, directoryHint: .isDirectory)
                    switch FolderProbe.kind(of: child) {
                    case .folder:
                        next.append(child)
                    case .other:
                        break
                    case .failure(let code) where code == EPERM || code == EACCES:
                        resolved.needsAccess.append(child)
                    case .failure(let code) where code == ENOENT || code == ENOTDIR:
                        break
                    case .failure:
                        resolved.incomplete = true
                    }
                }
                current = next
            }
        }
        resolved.roots = current.sorted { $0.plainPath < $1.plainPath }
        return resolved
    }

    private static func record(_ failure: FolderProbe.Failure, at url: URL, in resolved: inout ResolvedRoots) {
        switch failure {
        case .missing: resolved.missing.append(url)
        case .denied: resolved.needsAccess.append(url)
        case .other: resolved.incomplete = true
        }
    }

    /// Same folding the matcher uses for names: canonically composed and lowercased.
    private static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// Small read-only file system probes. Nothing here follows a symbolic link in its last component.
enum FolderProbe {
    enum Failure: Error, Sendable {
        /// `ENOENT`, `ENOTDIR`, or the last component is a symbolic link or a file.
        case missing
        /// `EPERM` or `EACCES`.
        case denied
        /// Anything else.
        case other
    }

    enum Kind {
        case folder
        /// A symbolic link, file or other non-folder.
        case other
        case failure(Int32)
    }

    /// `lstat` of `url`: never follows a final symbolic link.
    static func kind(of url: URL) -> Kind {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &info)
        }
        if result != 0 { return .failure(errno) }
        return info.st_mode & S_IFMT == S_IFDIR ? .folder : .other
    }

    /// Names of the real folders directly inside `url`, sorted. Symbolic links and files are left out.
    /// `url` itself must not be a symbolic link.
    static func childFolders(of url: URL) -> Result<[String], Failure> {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { return .failure(failure(for: errno)) }
        guard let directory = fdopendir(fd) else {
            let code = errno
            close(fd)
            return .failure(failure(for: code))
        }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name, name != ".", name != ".." else { continue }
            var isFolder = entry.pointee.d_type == UInt8(DT_DIR)
            if entry.pointee.d_type == UInt8(DT_UNKNOWN) {
                var info = stat()
                isFolder = fstatat(dirfd(directory), name, &info, AT_SYMLINK_NOFOLLOW) == 0
                    && info.st_mode & S_IFMT == S_IFDIR
            }
            if isFolder { names.append(name) }
        }
        return .success(names.sorted())
    }

    /// Fully resolved real path of `url`. Only for folders the caller supplied.
    static func realPath(of url: URL) -> Result<URL, Failure> {
        let resolved = url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, let buffer = realpath(path, nil) else { return nil }
            defer { free(buffer) }
            return String(validatingCString: buffer)
        }
        guard let resolved else { return .failure(failure(for: errno)) }
        return .success(URL(filePath: resolved, directoryHint: .isDirectory))
    }

    private static func failure(for code: Int32) -> Failure {
        switch code {
        case ENOENT, ENOTDIR, ELOOP: .missing
        case EPERM, EACCES: .denied
        default: .other
        }
    }
}

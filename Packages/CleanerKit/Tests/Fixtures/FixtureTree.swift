import Foundation

/// A throwaway folder tree for tests, created under
/// `<repo>/build/test-fixtures/<uuid>/` (or under `TC_FIXTURE_ROOT` when set).
///
/// Tests never touch the real home folder, `~/Library` or `/Library`. Every
/// method refuses (precondition failure) to create, change or remove anything
/// outside the tree's own root, including through a symlink.
public struct FixtureTree: Sendable {
    /// Errors from fixture setup.
    public enum FixtureError: Error, Sendable {
        case cannotCreate(String)
    }

    /// Real path (symlinks resolved) of this tree's unique folder.
    public let root: URL
    /// Folder that holds all fixture trees.
    private let base: URL

    /// Creates an empty tree with a fresh UUID folder.
    ///
    /// - Parameter filePath: Used to find the repo root. Leave the default.
    public init(filePath: StaticString = #filePath) throws {
        let configured = Self.configuredBase(filePath: filePath)
        let components = configured.standardizedFileURL.pathComponents
        precondition(configured.isFileURL && components.first == "/", "Fixture base must be absolute")
        precondition(components.count >= 3, "Fixture base is too shallow: \(configured.path)")

        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
        let realBase = configured.resolvingSymlinksInPath()
        self.base = realBase
        self.root = realBase.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    // MARK: Queries

    /// Whether `url` lies strictly inside this tree's root (lexically, after resolving `..`).
    public func contains(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.pathComponents
        let rootComponents = root.pathComponents
        return candidate.count > rootComponents.count && candidate.starts(with: rootComponents)
    }

    /// The absolute URL of a path relative to the root. Does not create anything.
    public func url(for relativePath: String) -> URL {
        let url = root.appending(path: relativePath).standardizedFileURL
        precondition(contains(url), "Path escapes the fixture root: \(relativePath)")
        return url
    }

    // MARK: Building

    /// Adds a regular file of `size` bytes, creating parent folders as needed.
    /// - Parameters:
    ///   - modified: Modification date to set. Defaults to now.
    @discardableResult
    public func addFile(_ relativePath: String, size: Int = 0, modified: Date? = nil) throws -> URL {
        precondition(size >= 0, "Negative file size")
        let url = try prepare(relativePath)
        precondition(!isSymlink(url), "Refusing to write through a symlink: \(relativePath)")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(count: size)) else {
            throw FixtureError.cannotCreate(relativePath)
        }
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    /// Adds a folder, creating parents as needed.
    ///
    /// Adding children later changes a folder's modification date, so set
    /// `modified` on a folder after its contents exist if a test depends on it.
    @discardableResult
    public func addDirectory(_ relativePath: String, modified: Date? = nil) throws -> URL {
        let url = try prepare(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    /// Adds a symbolic link at `relativePath` that points to `destination`.
    /// The destination may be anywhere; the link itself is inside the root.
    @discardableResult
    public func addSymlink(_ relativePath: String, destination: URL) throws -> URL {
        let url = try prepare(relativePath)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    /// Adds a hard link at `relativePath` to a file that is already inside the root.
    @discardableResult
    public func addHardLink(_ relativePath: String, to existing: URL) throws -> URL {
        precondition(contains(existing), "Hard link source must be inside the fixture root")
        precondition(!isSymlink(existing), "Hard link source must not be a symlink")
        let url = try prepare(relativePath)
        try FileManager.default.linkItem(at: existing, to: url)
        return url
    }

    /// Sets POSIX permissions (for example `0o000` for an unreadable folder).
    /// `remove()` restores access before deleting.
    public func setPermissions(_ relativePath: String, mode: Int) throws {
        let url = url(for: relativePath)
        precondition(!isSymlink(url), "Refusing to change permissions through a symlink")
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    // MARK: Removal

    /// Restores permissions on every folder in the tree, then deletes the tree.
    /// Refuses to act on anything that is not a UUID folder directly under the fixture base.
    public func remove() {
        precondition(
            root.deletingLastPathComponent().pathComponents == base.pathComponents
                && UUID(uuidString: root.lastPathComponent) != nil,
            "Refusing to remove a folder that is not a fixture root: \(root.path)"
        )
        guard !isSymlink(root) else {
            preconditionFailure("Fixture root is a symlink: \(root.path)")
        }
        restorePermissions(at: root)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Private

    private static func configuredBase(filePath: StaticString) -> URL {
        if let override = ProcessInfo.processInfo.environment["TC_FIXTURE_ROOT"], !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        // <repo>/Packages/CleanerKit/Tests/Fixtures/FixtureTree.swift
        var repo = URL(filePath: String(describing: filePath))
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        return repo.appending(path: "build/test-fixtures", directoryHint: .isDirectory)
    }

    /// Checks containment, makes parents, and returns the target URL.
    private func prepare(_ relativePath: String) throws -> URL {
        let url = url(for: relativePath)
        let parent = url.deletingLastPathComponent()

        // Walk up to the nearest ancestor that exists and make sure its real
        // path is still inside the root, so a symlinked folder cannot redirect us.
        var existing = parent
        while !FileManager.default.fileExists(atPath: existing.path) {
            existing.deleteLastPathComponent()
        }
        let real = existing.resolvingSymlinksInPath().pathComponents
        let rootComponents = root.pathComponents
        precondition(
            real.count >= rootComponents.count && real.starts(with: rootComponents),
            "Parent resolves outside the fixture root: \(relativePath)"
        )

        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return url
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func restorePermissions(at directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let child = directory.appending(path: name)
            // attributesOfItem uses lstat, so a symlink reports as a symlink and is skipped.
            guard let type = (try? fileManager.attributesOfItem(atPath: child.path))?[.type] as? FileAttributeType else {
                continue
            }
            if type == .typeDirectory {
                restorePermissions(at: child)
            } else if type == .typeRegular {
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: child.path)
            }
        }
    }
}

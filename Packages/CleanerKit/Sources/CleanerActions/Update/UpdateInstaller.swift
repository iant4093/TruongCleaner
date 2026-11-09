import Darwin
import Foundation

/// The file operations a swap needs. The real one uses `rename`; tests inject failures.
public protocol UpdateFileOperations: Sendable {
    /// Moves `source` to `destination`. `destination` must not exist.
    func move(_ source: URL, to destination: URL) throws
    /// Whether anything (including a broken link) exists at `url`.
    func itemExists(at url: URL) -> Bool
    /// Removes a half-copied bundle left at the app's path by a failed move.
    func removePartialCopy(at url: URL) throws
}

/// Moves with `rename(2)`, which is atomic on one volume, and falls back to `FileManager.moveItem`
/// when the two folders are on different volumes.
public struct SystemUpdateFileOperations: UpdateFileOperations {
    /// Creates the operations.
    public init() {}

    /// Renames, or moves across volumes.
    public func move(_ source: URL, to destination: URL) throws {
        let from = UpdateWorkspace.unixPath(source)
        let to = UpdateWorkspace.unixPath(destination)
        if rename(from, to) == 0 { return }
        guard errno == EXDEV else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    /// `lstat` succeeds.
    public func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(UpdateWorkspace.unixPath(url), &info) == 0
    }

    /// Removes the item. A link is removed as a link.
    public func removePartialCopy(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Replaces the running app with a verified new one, and puts the old one back if that fails.
public struct UpdateInstaller: Sendable {
    /// Start of the name the old bundle gets while the update runs.
    public static let oldBundlePrefix = ".TruongCleaner-old-"

    private let files: any UpdateFileOperations
    private let allowedParents: [String]

    /// Creates an installer.
    /// - Parameters:
    ///   - files: File operations. Tests inject failures.
    ///   - allowedParents: Folders the running app may live directly in.
    ///     Defaults to `/Applications` and `~/Applications`.
    public init(
        files: any UpdateFileOperations = SystemUpdateFileOperations(),
        allowedParents: [URL] = UpdateInstaller.standardParents()
    ) {
        self.files = files
        self.allowedParents = allowedParents.map { UpdateWorkspace.unixPath($0.resolvingSymlinksInPath()) }
    }

    /// `/Applications` and `~/Applications`.
    public static func standardParents() -> [URL] {
        [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    /// Why the app at `running` cannot update itself, or `nil` if it can: it must be a real `.app`
    /// (not a link) directly inside an allowed folder, and that folder must be writable.
    public func blocker(for running: URL) -> UpdateError? {
        let path = UpdateWorkspace.unixPath(running)
        var info = stat()
        guard running.pathExtension == "app", lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            return .installLocationNotSupported
        }
        let parent = UpdateWorkspace.unixPath(running.deletingLastPathComponent().resolvingSymlinksInPath())
        guard allowedParents.contains(parent) else { return .installLocationNotSupported }
        guard access(parent, W_OK) == 0 else { return .notWritable }
        return nil
    }

    /// Swaps `new` in for `running`.
    ///
    /// 1. Renames the running bundle to `.TruongCleaner-old-<uuid>.app` in the same folder
    ///    (macOS allows renaming a running app).
    /// 2. Moves `new` to the running app's path.
    /// 3. If step 2 fails, removes whatever it left at that path and renames the old bundle back.
    ///
    /// - Returns: Where the old bundle is now. ``UpdateCleanup`` trashes it on the next launch.
    /// - Throws: ``UpdateError``. After ``UpdateError/swapFailed(_:restoredOldApp:)`` the
    ///   `restoredOldApp` flag says whether the old version is back.
    public func swap(running: URL, new: URL) throws -> URL {
        if let blocker = blocker(for: running) { throw blocker }
        var info = stat()
        guard lstat(UpdateWorkspace.unixPath(new), &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, new.pathExtension == "app"
        else { throw UpdateError.unreadableBundle }

        let parent = running.deletingLastPathComponent()
        let aside = parent.appending(
            path: "\(Self.oldBundlePrefix)\(UUID().uuidString).app", directoryHint: .isDirectory)

        do {
            try files.move(running, to: aside)
        } catch {
            throw UpdateError.swapFailed(error.localizedDescription, restoredOldApp: true)
        }
        do {
            try files.move(new, to: running)
        } catch {
            // Whatever is at the app's path now was written by the failed move above: the original
            // was renamed away in step 1, so it is a partial copy of the new app.
            if files.itemExists(at: running) { try? files.removePartialCopy(at: running) }
            do {
                try files.move(aside, to: running)
            } catch {
                throw UpdateError.swapFailed(error.localizedDescription, restoredOldApp: false)
            }
            throw UpdateError.swapFailed(error.localizedDescription, restoredOldApp: true)
        }
        return aside
    }
}

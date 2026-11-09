import Foundation

/// The temporary folders an update uses: `TruongCleanerUpdate-<uuid>` under the temporary directory.
public enum UpdateWorkspace {
    /// Start of every update folder's name.
    public static let folderPrefix = "TruongCleanerUpdate-"

    /// Creates a fresh, private (0700) update folder inside `root`.
    public static func makeFolder(in root: URL) throws -> URL {
        let folder = root.appending(path: folderPrefix + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Whether the last path component is `TruongCleanerUpdate-` followed by a UUID.
    public static func isUpdateFolderName(_ name: String) -> Bool {
        guard name.hasPrefix(folderPrefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(folderPrefix.count))) != nil
    }

    /// Removes an update folder. Does nothing unless the name matches, the folder is a real
    /// directory (not a link) and it belongs to the current user. Errors are ignored: a folder left
    /// behind is removed by ``UpdateCleanup`` on a later launch.
    public static func discard(_ folder: URL) {
        guard isUpdateFolderName(folder.lastPathComponent), isOwnedDirectory(folder) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The path of a file URL without a trailing slash. A trailing slash makes `lstat` and `rename`
    /// follow a symbolic link, so every system call in the update code takes its path from here.
    static func unixPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `lstat` says directory (not a link) owned by the current user.
    static func isOwnedDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(unixPath(url), &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }
}

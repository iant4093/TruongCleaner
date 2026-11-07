import Foundation

/// Which folders count as a Trash: `~/.Trash` and `<volume>/.Trashes/<uid>`.
///
/// Put Back and Free Space Now act only on direct children of these folders.
public struct TrashLocations: Sendable {
    private let home: URL
    private let uid: UInt32
    private let additionalFolders: [URL]

    /// Creates the locations for a user.
    ///
    /// - Parameters:
    ///   - home: The user's home folder; `<home>/.Trash` is a Trash.
    ///   - uid: The user ID that names `.Trashes/<uid>` on other volumes.
    ///   - additionalFolders: Extra Trash folders. Tests use a folder inside a fixture.
    public init(home: URL, uid: UInt32 = UInt32(getuid()), additionalFolders: [URL] = []) {
        self.home = home
        self.uid = uid
        self.additionalFolders = additionalFolders
    }

    /// Whether `url` is a direct child of a Trash folder.
    ///
    /// The parent's real path is used, so a link inside a Trash that points elsewhere does not count.
    /// The item itself is not resolved. Any failure answers false.
    public func contains(_ url: URL) -> Bool {
        guard url.isFileURL, let name = PathParts.components(of: url)?.last, name != ".", name != ".." else {
            return false
        }
        guard let parent = try? GateSystem.realPath(of: url.deletingLastPathComponent()) else { return false }
        return isTrashFolder(parent)
    }

    /// Whether the real path `folder` is a Trash folder.
    private func isTrashFolder(_ folder: URL) -> Bool {
        guard let parts = PathParts.components(of: folder) else { return false }
        let candidates = [home.appending(path: ".Trash", directoryHint: .isDirectory)] + additionalFolders
        for candidate in candidates {
            if let real = realOrGiven(candidate), PathParts.components(of: real) == parts { return true }
        }
        return Self.isVolumeTrash(parts, uid: uid)
    }

    /// Whether the components name `<volume root>/.Trashes/<uid>` for the startup volume,
    /// a mounted volume or the Data volume.
    static func isVolumeTrash(_ parts: [String], uid: UInt32) -> Bool {
        guard parts.count >= 2, parts[parts.count - 2] == ".Trashes", parts[parts.count - 1] == String(uid) else {
            return false
        }
        let volume = Array(parts.dropLast(2))
        return volume.isEmpty
            || (volume.count == 2 && volume[0] == "Volumes")
            || volume == ["System", "Volumes", "Data"]
    }

    /// The real path of a folder, or the folder itself when it does not exist (yet).
    private func realOrGiven(_ url: URL) -> URL? {
        if let real = try? GateSystem.realPath(of: url) { return real }
        guard let parent = try? GateSystem.realPath(of: url.deletingLastPathComponent()) else { return nil }
        return parent.appending(path: url.lastPathComponent, directoryHint: .isDirectory)
    }
}

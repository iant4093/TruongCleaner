import Foundation

/// Unpacks the downloaded ZIP with `/usr/bin/ditto -x -k`.
///
/// Same launch rules as ``OwnerProcess``: an absolute path, fixed argv, scrubbed environment, no
/// shell, a timeout. The result must be exactly one `TruongCleaner.app` directory and nothing else.
public struct UpdateUnpacker: Sendable {
    /// Name of the app inside the ZIP.
    public static let appName = "TruongCleaner.app"
    private static let extractFolderName = "extract"

    private let dittoPath: String
    private let timeout: Duration

    /// Creates an unpacker that runs `/usr/bin/ditto` with a 60 s timeout.
    public init() {
        self.init(dittoPath: "/usr/bin/ditto", timeout: .seconds(60))
    }

    init(dittoPath: String, timeout: Duration) {
        self.dittoPath = dittoPath
        self.timeout = timeout
    }

    /// Unpacks `download.archive` into `<folder>/extract` and returns the app's URL.
    ///
    /// - Throws: ``UpdateError/unpackFailed(_:)`` or ``UpdateError/unexpectedArchiveContents``.
    ///   The folder is left for the caller to discard.
    @concurrent
    public func unpack(_ download: DownloadedUpdate) async throws -> URL {
        let target = download.folder.appending(path: Self.extractFolderName, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw UpdateError.unpackFailed("cannot create a temporary folder")
        }
        switch OwnerProcess.check(executable: dittoPath) {
        case .ok: break
        case .missing: throw UpdateError.unpackFailed("ditto is missing")
        case .refused(let reason): throw UpdateError.unpackFailed(reason)
        }
        let outcome = await OwnerProcess.run(
            dittoPath,
            ["-x", "-k", download.archive.path(percentEncoded: false), target.path(percentEncoded: false)],
            timeout: timeout)
        if outcome.timedOut { throw UpdateError.unpackFailed("it took too long") }
        if let launchError = outcome.launchError { throw UpdateError.unpackFailed(launchError) }
        guard outcome.exitCode == 0 else { throw UpdateError.unpackFailed("ditto failed") }
        try Task.checkCancellation()
        return try Self.checkContents(of: download.folder, extractFolder: target)
    }

    /// The update folder must hold only the ZIP, `SHA256SUMS` and `extract`, and `extract` must hold
    /// one real `TruongCleaner.app` directory. Anything else, such as a path that escaped upward,
    /// a second top-level item or a link, is refused.
    static func checkContents(of folder: URL, extractFolder: URL) throws -> URL {
        let fileManager = FileManager.default
        let expectedInFolder: Set<String> = [UpdateDownloader.archiveName, "SHA256SUMS", extractFolderName]
        guard let outer = try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)),
              Set(outer) == expectedInFolder
        else { throw UpdateError.unexpectedArchiveContents }
        guard let inner = try? fileManager.contentsOfDirectory(atPath: extractFolder.path(percentEncoded: false)),
              inner == [appName]
        else { throw UpdateError.unexpectedArchiveContents }
        let app = extractFolder.appending(path: appName, directoryHint: .isDirectory)
        var info = stat()
        guard lstat(UpdateWorkspace.unixPath(app), &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw UpdateError.unexpectedArchiveContents
        }
        return app
    }
}

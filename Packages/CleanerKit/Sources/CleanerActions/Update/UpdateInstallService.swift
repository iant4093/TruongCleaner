import Foundation

/// A downloaded, unpacked and verified update waiting to be swapped in.
public struct PreparedUpdate: Sendable, Equatable {
    /// The `TruongCleanerUpdate-<uuid>` folder to discard afterwards.
    public let folder: URL
    /// The verified new app and its build number.
    public let verified: VerifiedUpdate
}

/// Where an update is in its first half, for the progress display.
public enum UpdateStage: Sendable, Equatable {
    /// Downloading; the value is the fraction received, 0 to 1.
    case downloading(Double)
    /// Unpacking and checking.
    case verifying
}

/// Runs the update steps in order: download and checksum, unpack, verify, then swap.
public struct UpdateInstallService: Sendable {
    private let downloader: UpdateDownloader
    private let unpacker: UpdateUnpacker
    private let verifier: UpdateVerifier
    private let installer: UpdateInstaller

    /// Creates the service with the real parts.
    public init() {
        self.init(
            downloader: UpdateDownloader(), unpacker: UpdateUnpacker(),
            verifier: UpdateVerifier(), installer: UpdateInstaller())
    }

    /// Creates the service with injected parts. Tests pass a fake fetcher and installer folders.
    public init(
        downloader: UpdateDownloader, unpacker: UpdateUnpacker = UpdateUnpacker(),
        verifier: UpdateVerifier = UpdateVerifier(), installer: UpdateInstaller = UpdateInstaller()
    ) {
        self.downloader = downloader
        self.unpacker = unpacker
        self.verifier = verifier
        self.installer = installer
    }

    /// Why the app at `running` cannot update itself, or `nil`.
    public func blocker(for running: URL) -> UpdateError? {
        installer.blocker(for: running)
    }

    /// Downloads, checks the checksum, unpacks and verifies. Nothing is installed.
    ///
    /// - Throws: ``UpdateError``. The temporary folder is removed when this throws.
    @concurrent
    public func prepare(
        _ assets: UpdateAssets, identity: UpdateIdentity,
        onStage: @escaping @Sendable (UpdateStage) -> Void
    ) async throws -> PreparedUpdate {
        let downloaded = try await downloader.download(assets) { onStage(.downloading($0)) }
        do {
            onStage(.verifying)
            let app = try await unpacker.unpack(downloaded)
            let verified = try await verifier.verify(app, against: identity)
            return PreparedUpdate(folder: downloaded.folder, verified: verified)
        } catch is CancellationError {
            UpdateWorkspace.discard(downloaded.folder)
            throw UpdateError.cancelled
        } catch {
            UpdateWorkspace.discard(downloaded.folder)
            throw error
        }
    }

    /// Swaps the prepared app in for `running`, then discards the temporary folder.
    ///
    /// - Returns: Where the old bundle went. The next launch trashes it.
    /// - Throws: ``UpdateError``; the temporary folder is removed either way.
    @concurrent
    public func install(_ prepared: PreparedUpdate, replacing running: URL) async throws -> URL {
        defer { UpdateWorkspace.discard(prepared.folder) }
        return try installer.swap(running: running, new: prepared.verified.app)
    }

    /// Discards a prepared update that will not be installed.
    public func discard(_ prepared: PreparedUpdate) {
        UpdateWorkspace.discard(prepared.folder)
    }
}

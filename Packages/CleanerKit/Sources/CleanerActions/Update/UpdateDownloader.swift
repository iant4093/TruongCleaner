import CryptoKit
import Foundation
import os

/// A downloaded and checksum-verified update, still zipped.
public struct DownloadedUpdate: Sendable, Equatable {
    /// The `TruongCleanerUpdate-<uuid>` folder that holds everything for this update.
    public let folder: URL
    /// `TruongCleaner.zip` inside ``folder``. Its SHA-256 matched `SHA256SUMS`.
    public let archive: URL
}

/// Reads `SHA256SUMS`, the file the release workflow publishes (`shasum -a 256` format).
public enum UpdateChecksums {
    /// The hex digest on the line for `fileName`, lowercased. `nil` unless exactly one line names
    /// the file and its digest is 64 hex digits.
    public static func expectedDigest(for fileName: String, in text: String) -> String? {
        var found: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : parts[1]
            if name == fileName { found.append(parts[0]) }
        }
        guard found.count == 1, let digest = found.first, digest.count == 64,
              digest.allSatisfy(\.isHexDigit)
        else { return nil }
        return digest.lowercased()
    }

    /// SHA-256 of a file as lowercase hex, read in 1 MB pieces.
    public static func digest(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty {
            hasher.update(data: piece)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Downloads `SHA256SUMS`, `SHA256SUMS.sig` and `TruongCleaner.zip`. The signature must verify over
/// the exact `SHA256SUMS` bytes before the ZIP is fetched, and the ZIP must match its line in them.
///
/// Addresses must pass ``UpdateURLPolicy``. The work happens in a fresh folder under `workRoot`.
/// A missing or bad signature, a checksum mismatch, a missing checksum, a timeout or a cancel
/// removes that folder and throws.
public struct UpdateDownloader: Sendable {
    /// Longest the ZIP may be (the app is under 5 MB; this leaves room and bounds the disk use).
    public static let maxArchiveBytes: Int64 = 100 * 1024 * 1024
    /// Longest `SHA256SUMS` may be.
    public static let maxChecksumBytes: Int64 = 64 * 1024
    /// Longest `SHA256SUMS.sig` may be.
    public static let maxSignatureBytes = Int64(UpdateTrust.maxSignatureFileBytes)
    /// File name of the archive inside a release.
    public static let archiveName = "TruongCleaner.zip"

    private let fetcher: any UpdateFetcher
    private let workRoot: URL
    private let timeLimit: Duration
    private let trust: UpdateTrust

    /// Creates a downloader.
    /// - Parameters:
    ///   - fetcher: Serves the files. Tests pass a fake.
    ///   - workRoot: Folder that gets the `TruongCleanerUpdate-<uuid>` folder.
    ///   - timeLimit: Total time for all files. Five minutes by default.
    ///   - trust: The keys `SHA256SUMS.sig` must verify against. The embedded production keys by
    ///     default; tests pass their own.
    public init(
        fetcher: any UpdateFetcher = URLSessionUpdateFetcher(),
        workRoot: URL = FileManager.default.temporaryDirectory,
        timeLimit: Duration = .seconds(300),
        trust: UpdateTrust = .production
    ) {
        self.fetcher = fetcher
        self.workRoot = workRoot
        self.timeLimit = timeLimit
        self.trust = trust
    }

    /// Downloads and verifies the update.
    ///
    /// - Parameter progress: Fraction of the ZIP received, 0 to 1, at most 10 times a second.
    /// - Throws: ``UpdateError``. Nothing is left on disk when it throws.
    @concurrent
    public func download(
        _ assets: UpdateAssets, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DownloadedUpdate {
        // An unsigned release is refused before anything is fetched or written.
        guard let signatureURL = assets.signature else { throw UpdateError.unsigned }
        // Re-check here: `UpdateAssets` validates on creation, and this is the door to the network.
        guard UpdateURLPolicy.isAllowedAssetURL(assets.archive) else {
            throw UpdateError.disallowedURL(assets.archive.absoluteString)
        }
        guard UpdateURLPolicy.isAllowedAssetURL(assets.checksums) else {
            throw UpdateError.disallowedURL(assets.checksums.absoluteString)
        }
        guard UpdateURLPolicy.isAllowedAssetURL(signatureURL) else {
            throw UpdateError.disallowedURL(signatureURL.absoluteString)
        }
        let folder: URL
        do {
            folder = try UpdateWorkspace.makeFolder(in: workRoot)
        } catch {
            throw UpdateError.downloadFailed("cannot create a temporary folder")
        }
        do {
            let result = try await withTimeLimit {
                try await self.fetchAndCheck(assets, signatureURL: signatureURL, in: folder, progress: progress)
            }
            return result
        } catch {
            UpdateWorkspace.discard(folder)
            throw Self.map(error)
        }
    }

    // MARK: Private

    private func fetchAndCheck(
        _ assets: UpdateAssets, signatureURL: URL, in folder: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DownloadedUpdate {
        let sumsFile = folder.appending(path: "SHA256SUMS", directoryHint: .notDirectory)
        let signatureFile = folder.appending(path: "SHA256SUMS.sig", directoryHint: .notDirectory)
        let archive = folder.appending(path: Self.archiveName, directoryHint: .notDirectory)

        try await fetcher.fetch(assets.checksums, to: sumsFile, maxBytes: Self.maxChecksumBytes) { _, _ in }
        try await fetcher.fetch(signatureURL, to: signatureFile, maxBytes: Self.maxSignatureBytes) { _, _ in }
        try Task.checkCancellation()

        // The signature covers the exact bytes read here. Those same bytes are parsed below, so the
        // file is not read a second time. Unknown means keep: an unreadable file stops the update.
        guard let sumsData = try? Data(contentsOf: sumsFile),
              let signatureData = try? Data(contentsOf: signatureFile),
              trust.isValid(signatureFile: signatureData, for: sumsData)
        else { throw UpdateError.badSignature }

        let throttle = ProgressThrottle(progress)
        try await fetcher.fetch(assets.archive, to: archive, maxBytes: Self.maxArchiveBytes) { received, expected in
            guard let expected, expected > 0 else { return }
            throttle.report(Double(received) / Double(expected))
        }
        try Task.checkCancellation()

        guard let text = String(data: sumsData, encoding: .utf8),
              let expected = UpdateChecksums.expectedDigest(for: Self.archiveName, in: text)
        else { throw UpdateError.checksumMissing }
        guard let actual = try? UpdateChecksums.digest(ofFileAt: archive), actual == expected else {
            throw UpdateError.checksumMismatch
        }
        progress(1)
        return DownloadedUpdate(folder: folder, archive: archive)
    }

    /// Runs `work` and throws ``UpdateError/timedOut`` if it takes longer than the limit.
    private func withTimeLimit<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let limit = timeLimit
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw UpdateError.cancelled }
            guard let value = first else { throw UpdateError.timedOut }
            return value
        }
    }

    private static func map(_ error: any Error) -> UpdateError {
        if let error = error as? UpdateError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            return error.code == .cancelled ? .cancelled : .downloadFailed(error.localizedDescription)
        }
        return .downloadFailed(error.localizedDescription)
    }
}

/// Passes progress on at most 10 times a second (and always the final value).
private final class ProgressThrottle: Sendable {
    private let sink: @Sendable (Double) -> Void
    private let last = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    init(_ sink: @escaping @Sendable (Double) -> Void) { self.sink = sink }

    func report(_ fraction: Double) {
        let now = ContinuousClock.now
        let due = last.withLock { previous -> Bool in
            if let previous, now - previous < .milliseconds(100), fraction < 1 { return false }
            previous = now
            return true
        }
        if due { sink(min(max(fraction, 0), 1)) }
    }
}

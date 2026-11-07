import Foundation

/// Moves or deletes one item. Called only after `SafetyGate` allowed it.
public protocol ItemExecutor: Sendable {
    /// Moves the item to the Trash.
    /// - Returns: The item's location in the Trash.
    func moveToTrash(_ url: URL) async throws -> URL
    /// Deletes the item for good. A symbolic link is removed as a link; its target is never touched.
    func deletePermanently(_ url: URL) async throws
}

/// Failures of `FileManagerExecutor`.
public enum ExecutorError: Error, Sendable, Equatable {
    /// The system moved the item but did not say where.
    case trashLocationUnknown
    /// The URL is not an absolute file URL.
    case notAFileURL
}

/// The production executor. It is the only one the app uses.
///
/// Moving uses `FileManager.trashItem`, which works off the main thread and keeps the file ID
/// (spike S3, `docs/EVIDENCE.md`). It never falls back to deleting when the Trash is unavailable.
public struct FileManagerExecutor: ItemExecutor {
    /// Creates an executor.
    public init() {}

    /// Moves the item to the Trash and returns its new location.
    @concurrent
    public func moveToTrash(_ url: URL) async throws -> URL {
        guard url.isFileURL, url.path(percentEncoded: false).hasPrefix("/") else { throw ExecutorError.notAFileURL }
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let resulting else { throw ExecutorError.trashLocationUnknown }
        return resulting as URL
    }

    /// Deletes the item for good.
    @concurrent
    public func deletePermanently(_ url: URL) async throws {
        guard url.isFileURL, url.path(percentEncoded: false).hasPrefix("/") else { throw ExecutorError.notAFileURL }
        try FileManager.default.removeItem(at: url)
    }
}

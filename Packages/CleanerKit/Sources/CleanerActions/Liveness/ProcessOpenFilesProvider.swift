import CleanerCore
import Darwin
import Foundation

/// Finds processes that have an item, or a file inside it, open.
///
/// Every question takes a fresh ``OpenFilesSnapshot`` through ``ProcessInspector`` (about 120 ms) and
/// answers from it. A hit means a path is the item or lies below it, or an open file is the item
/// itself by `(device, inode)` (so a hard link or a differently spelled path is still found).
///
/// Processes the user may not inspect (other users', system daemons) cannot be seen by any
/// user-level tool and are skipped. Any other failure makes the answer nil, which the gate treats
/// as "keep". See ``ProcessInspector`` for the rules.
public struct ProcessOpenFilesProvider: OpenFilesProvider {
    private let excludedPIDs: Set<Int32>

    /// Creates a provider.
    ///
    /// - Parameter excludingPIDs: Processes to ignore. The default is this process, so the
    ///   app's own scan handles never block a clean.
    public init(excludingPIDs: Set<Int32> = [getpid()]) {
        self.excludedPIDs = excludingPIDs
    }

    /// `true` when a process has the item or a file inside it open, `false` when none does,
    /// `nil` when this could not be determined.
    public func hasOpenFiles(under url: URL) async -> Bool? {
        await ProcessInspector.captureOffPool(excluding: excludedPIDs).answer(for: url)
    }
}

import Foundation

/// Why Put Back did nothing.
public enum PutBackRefusal: String, Sendable, Codable, Equatable {
    /// The history entry is not a move to the Trash.
    case notMoved
    /// The recorded Trash location is not directly inside a Trash folder.
    case outsideTrash
    /// Nothing is at the recorded Trash location any more (emptied, or moved again).
    case goneFromTrash
    /// Something else is at the recorded Trash location: its file ID differs.
    case changedSinceClean
    /// The folder the item came from is gone.
    case originalFolderMissing
    /// Something already exists at the original path.
    case originalPathTaken

    /// A short sentence in plain words.
    public var userMessage: String {
        switch self {
        case .notMoved: "This item was not moved to the Trash"
        case .outsideTrash: "It is not in the Trash"
        case .goneFromTrash: "It is no longer in the Trash"
        case .changedSinceClean: "The item in the Trash is not the one that was moved"
        case .originalFolderMissing: "The folder it came from no longer exists"
        case .originalPathTaken: "Something else is already at its old location"
        }
    }
}

/// The result of Put Back for one item.
public enum PutBackResult: Sendable, Equatable {
    /// The item is back at this path.
    case restored(URL)
    /// Nothing was changed, for this reason.
    case refused(PutBackRefusal)
    /// The move failed. Nothing was changed.
    case failed(String)
}

/// The result of Free Space Now.
public struct FreeSpaceReport: Sendable {
    /// An item left in the Trash, with the reason.
    public struct Skipped: Sendable {
        /// The item.
        public let item: ItemReport
        /// A plain sentence.
        public let reason: String
    }

    /// Items deleted for good from the Trash.
    public var freed: [ItemReport] = []
    /// Items left alone.
    public var skipped: [Skipped] = []
    /// Items whose deletion failed.
    public var failed: [Skipped] = []

    /// Estimated space freed: private bytes of the deleted items.
    public var freedBytes: Int64 { freed.reduce(0) { $0 + $1.privateBytes } }

    /// Creates an empty report.
    public init() {}
}

/// Put Back and Free Space Now. Both act only on items that history says this app moved.
public struct UndoService: Sendable {
    private let trash: TrashLocations

    /// Creates the service.
    /// - Parameter trash: The Trash folders it may act in.
    public init(trash: TrashLocations) {
        self.trash = trash
    }

    /// Moves an item back from the Trash to its original path.
    ///
    /// It does so only if the recorded Trash location is directly inside a Trash, an entry there has
    /// the recorded file ID, the original folder exists and the original path is free.
    /// On success it writes an `undone` line.
    public func putBack(_ item: ItemReport, cleanID: UUID, history: HistoryStore) async -> PutBackResult {
        guard case .moved(let trashURL) = item.outcome else { return .refused(.notMoved) }
        if let refusal = inspectTrashed(trashURL, fileID: item.fileID) { return .refused(refusal) }

        // The original folder must exist; resolve its real path so we never write through a stale link.
        let originalParent = item.originalPath.deletingLastPathComponent()
        guard let realParent = try? GateSystem.realPath(of: originalParent),
            let info = try? GateSystem.lstatInfo(of: realParent), GateSystem.isDirectory(info)
        else { return .refused(.originalFolderMissing) }
        let destination = realParent.appending(path: item.originalPath.lastPathComponent, directoryHint: .inferFromPath)
        if (try? GateSystem.lstatInfo(of: destination)) != nil { return .refused(.originalPathTaken) }

        do {
            // FileManager.moveItem fails if the destination exists, so a race cannot overwrite.
            try FileManager.default.moveItem(at: trashURL, to: destination)
        } catch {
            return .failed(error.localizedDescription)
        }
        // The move happened. If the note fails, the result is still reported as it is.
        try? await history.recordUndone(findingID: item.findingID, cleanID: cleanID, restoredTo: destination)
        return .restored(destination)
    }

    /// Deletes for good the items this app moved to the Trash, so their space is freed.
    ///
    /// Only items from history with outcome `moved`, not put back or freed since, still at the
    /// recorded Trash location with the recorded file ID, and directly inside a Trash folder.
    /// Nothing else in the Trash is touched. Each deletion writes a `freed` line; if that cannot be
    /// written, the run stops.
    public func freeSpaceNow(history: HistoryStore, executor: any ItemExecutor) async -> FreeSpaceReport {
        var report = FreeSpaceReport()
        let candidates: [TrashedItem]
        do {
            candidates = try await history.trashedItems()
        } catch {
            return report
        }
        var historyWorks = true
        for candidate in candidates {
            let item = candidate.item
            guard historyWorks else {
                report.skipped.append(.init(item: item, reason: "History is unavailable, so nothing more was deleted"))
                continue
            }
            if let refusal = inspectTrashed(candidate.trashURL, fileID: item.fileID) {
                report.skipped.append(.init(item: item, reason: refusal.userMessage))
                continue
            }
            do {
                try await executor.deletePermanently(candidate.trashURL)
            } catch {
                report.failed.append(.init(item: item, reason: error.localizedDescription))
                continue
            }
            report.freed.append(item)
            do {
                try await history.recordFreed(findingID: item.findingID, cleanID: candidate.cleanID, trashURL: candidate.trashURL)
            } catch {
                historyWorks = false
            }
        }
        return report
    }

    /// Nil when `trashURL` is a direct child of a Trash and has file ID `fileID`; otherwise why not.
    private func inspectTrashed(_ trashURL: URL, fileID: UInt64) -> PutBackRefusal? {
        guard trash.contains(trashURL) else { return .outsideTrash }
        do {
            let current = try GateSystem.identity(of: trashURL)
            return current.fileID == fileID ? nil : .changedSinceClean
        } catch let error as SysError {
            return error.isMissing ? .goneFromTrash : .changedSinceClean
        } catch {
            return .changedSinceClean
        }
    }
}

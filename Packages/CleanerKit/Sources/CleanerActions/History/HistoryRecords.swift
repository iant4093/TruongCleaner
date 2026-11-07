import Foundation

/// An item as the plan listed it, written with `begin` before anything is touched.
struct PlannedRecord: Codable {
    var findingID: UUID
    var ruleID: String
    var originalPath: URL
    var fsid: UInt64
    var fileID: UInt64
    var estimatedBytes: Int64
    var privateBytes: Int64
}

/// One line of `history.jsonl`. `type` says which fields are set.
struct HistoryLine: Codable {
    enum Kind {
        static let begin = "begin"
        static let item = "item"
        static let finish = "finish"
        static let undone = "undone"
        static let freed = "freed"
    }

    var type: String
    var cleanID: UUID
    var at: Date
    // begin
    var mode: DeleteMode?
    var permanentConfirmed: Bool?
    var planned: [PlannedRecord]?
    // item
    var item: ItemReport?
    // finish
    var startedAt: Date?
    var availableBefore: Int64?
    var availableAfter: Int64?
    // undone, freed
    var findingID: UUID?
    var path: URL?
}

/// What one clean did, for the History page.
public struct CleanSummary: Sendable, Codable, Identifiable, Equatable {
    /// ID of the clean.
    public let id: UUID
    /// When it began.
    public let startedAt: Date
    /// When it ended. Nil when the app stopped before the clean finished.
    public let finishedAt: Date?
    /// Trash or permanent.
    public let mode: DeleteMode
    /// Items in the plan.
    public let plannedCount: Int
    /// Items moved to the Trash.
    public let movedCount: Int
    /// Items deleted for good.
    public let deletedCount: Int
    /// Items left alone.
    public let skippedCount: Int
    /// Items that failed.
    public let failedCount: Int
    /// Estimated space to be freed (private bytes of moved and deleted items).
    public let estimatedFreedBytes: Int64
    /// Available space before the clean, if it was read.
    public let availableBefore: Int64?
    /// Available space after the clean, if it was read.
    public let availableAfter: Int64?

    /// Whether the clean wrote its `finish` entry.
    public var isFinished: Bool { finishedAt != nil }
}

/// A later change to an item that a clean had moved to the Trash.
public struct HistoryFollowUp: Sendable, Codable, Equatable {
    /// What happened to the item afterwards.
    public enum Kind: String, Sendable, Codable {
        /// Put back at its original path.
        case undone
        /// Deleted for good from the Trash by Free Space Now.
        case freed
    }

    /// What happened.
    public let kind: Kind
    /// The clean that moved the item.
    public let cleanID: UUID
    /// The item's finding.
    public let findingID: UUID
    /// When it happened.
    public let at: Date
    /// Where the item was restored to (`undone`) or where it was deleted from (`freed`).
    public let path: URL
}

/// An item that a clean moved to the Trash and that has not been put back or freed since.
public struct TrashedItem: Sendable {
    /// The clean that moved it.
    public let cleanID: UUID
    /// The record of the move.
    public let item: ItemReport
    /// Where the item was put in the Trash.
    public let trashURL: URL
}

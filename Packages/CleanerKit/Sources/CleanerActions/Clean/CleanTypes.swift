import CleanerCore
import Foundation

/// How approved items leave their place.
public enum DeleteMode: String, Sendable, Codable {
    /// Move to the Trash. The default; it can be undone.
    case trash
    /// Delete for good. Needs `CleanPlan.permanentConfirmed`.
    case permanent
}

/// One finding together with the rule that produced it and the roots that rule was scanned in.
public struct PlannedItem: Sendable {
    /// The item as the scan recorded it.
    public let finding: Finding
    /// The rule that produced the finding.
    public let rule: Rule
    /// The rule's concrete roots, as they were scanned.
    public let expandedRoots: [URL]

    /// Creates a planned item.
    public init(finding: Finding, rule: Rule, expandedRoots: [URL]) {
        self.finding = finding
        self.rule = rule
        self.expandedRoots = expandedRoots
    }
}

/// What the user chose to clean.
public struct CleanPlan: Sendable {
    /// Items, processed one after another in this order.
    public var items: [PlannedItem]
    /// Move to the Trash or delete for good.
    public var mode: DeleteMode
    /// Must be true when `mode == .permanent`. Otherwise the whole run is refused and nothing changes.
    public var permanentConfirmed: Bool

    /// Creates a plan.
    public init(items: [PlannedItem], mode: DeleteMode = .trash, permanentConfirmed: Bool = false) {
        self.items = items
        self.mode = mode
        self.permanentConfirmed = permanentConfirmed
    }
}

/// What happened to one item.
public enum ItemOutcome: Sendable, Codable, Equatable {
    /// Moved to the Trash. Holds the item's location there.
    case moved(to: URL)
    /// Deleted for good.
    case deleted
    /// Left alone, for this reason.
    case skipped(DenyReason)
    /// The attempt failed. Holds a plain-words message.
    case failed(String)
}

/// The result for one item, as shown to the user and written to history.
public struct ItemReport: Sendable, Codable {
    /// ID of the finding.
    public let findingID: UUID
    /// ID of the rule that produced the finding.
    public let ruleID: String
    /// Where the item was before the clean.
    public let originalPath: URL
    /// File system ID at scan time.
    public let fsid: UInt64
    /// File ID at scan time. Put Back and Free Space Now compare it again.
    public let fileID: UInt64
    /// Allocated bytes on disk at scan time.
    public let estimatedBytes: Int64
    /// Bytes only this item owns (not shared with clones). The "space to be freed" estimate.
    public let privateBytes: Int64
    /// What happened.
    public let outcome: ItemOutcome

    /// Creates a report.
    public init(
        findingID: UUID,
        ruleID: String,
        originalPath: URL,
        fsid: UInt64,
        fileID: UInt64,
        estimatedBytes: Int64,
        privateBytes: Int64,
        outcome: ItemOutcome
    ) {
        self.findingID = findingID
        self.ruleID = ruleID
        self.originalPath = originalPath
        self.fsid = fsid
        self.fileID = fileID
        self.estimatedBytes = estimatedBytes
        self.privateBytes = privateBytes
        self.outcome = outcome
    }

    /// Creates a report for `finding` with `outcome`.
    init(_ finding: Finding, outcome: ItemOutcome) {
        self.init(
            findingID: finding.id,
            ruleID: finding.ruleID,
            originalPath: finding.url,
            fsid: finding.fsid,
            fileID: finding.fileID,
            estimatedBytes: finding.allocatedBytes,
            privateBytes: finding.privateBytes,
            outcome: outcome
        )
    }

    /// Whether the item left its place (moved or deleted).
    public var didRemove: Bool {
        switch outcome {
        case .moved, .deleted: true
        case .skipped, .failed: false
        }
    }
}

/// The full result of one clean.
public struct CleanReport: Sendable, Codable {
    /// ID shared with the history entries of this clean.
    public let id: UUID
    /// When the clean began.
    public let startedAt: Date
    /// When the clean ended.
    public let finishedAt: Date
    /// The mode the user chose.
    public let mode: DeleteMode
    /// One entry per planned item, in plan order.
    public let items: [ItemReport]
    /// Available space (important usage) on the home volume before the first item. Nil if unreadable.
    public let availableBefore: Int64?
    /// Available space after the last item. Nil if unreadable.
    public let availableAfter: Int64?

    /// Creates a report.
    public init(
        id: UUID,
        startedAt: Date,
        finishedAt: Date,
        mode: DeleteMode,
        items: [ItemReport],
        availableBefore: Int64?,
        availableAfter: Int64?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.mode = mode
        self.items = items
        self.availableBefore = availableBefore
        self.availableAfter = availableAfter
    }

    /// Change in available space, `after - before`. Can be negative or near zero: items moved to
    /// the Trash still occupy space until the Trash is emptied. Nil when either reading failed.
    public var measuredFreedBytes: Int64? {
        guard let availableBefore, let availableAfter else { return nil }
        return availableAfter - availableBefore
    }

    /// Estimated space to be freed: private bytes of every item that was moved or deleted.
    public var estimatedFreedBytes: Int64 {
        items.filter(\.didRemove).reduce(0) { $0 + $1.privateBytes }
    }
}

/// Progress of a running clean.
public struct CleanProgress: Sendable {
    /// Items finished so far.
    public let done: Int
    /// Items in the plan.
    public let total: Int
    /// The item about to be handled, or nil when the run is over.
    public let current: URL?

    /// Creates a progress value.
    public init(done: Int, total: Int, current: URL?) {
        self.done = done
        self.total = total
        self.current = current
    }
}

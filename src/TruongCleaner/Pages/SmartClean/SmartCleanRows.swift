import CleanerActions
import CleanerCore
import CleanerScanner
import Foundation

/// Files and bytes counted so far by a running scan.
struct ScanProgress: Sendable, Equatable {
    var files = 0
    var allocatedBytes: Int64 = 0
}

/// One rule's row in the results: the rule, what the scan found, and the biggest items to list.
struct SmartCleanRow: Identifiable {
    /// Most items listed under a row. The clean still covers every finding of a selected rule.
    static let listLimit = 200

    let rule: Rule
    let result: RuleResult
    /// The largest findings, biggest first, at most ``listLimit``.
    let topFindings: [Finding]

    var id: String { rule.id }

    /// Info rows show a size and never have a checkbox or an action.
    var isInfo: Bool { rule.tier == .info }

    /// Whether the row has a checkbox: something was found and the rule is not Info.
    var isSelectable: Bool { !isInfo && !result.findings.isEmpty }

    /// Whether some folders of the rule could not be opened.
    var needsAccess: Bool { !result.needsAccess.isEmpty }

    /// Allocated bytes on disk.
    var bytes: Int64 { result.measuredBytes }

    /// Bytes only these items own (not shared with APFS clones). The "at least" figure.
    var privateBytes: Int64 { result.measuredPrivateBytes }

    /// The row is worth showing: it found something, needs access, or is an Info row with a size.
    var isVisible: Bool {
        !result.findings.isEmpty || needsAccess || (isInfo && result.measuredBytes > 0)
    }

    /// The size is unknown, not zero: nothing was measured and a folder refused to open.
    var sizeIsUnknown: Bool { result.measuredBytes == 0 && needsAccess }

    init(rule: Rule, result: RuleResult) {
        self.rule = rule
        self.result = result
        self.topFindings = Array(
            result.findings.sorted { $0.allocatedBytes > $1.allocatedBytes }.prefix(Self.listLimit)
        )
    }
}

/// All visible rows of one category.
struct SmartCleanSection: Identifiable {
    let category: CleanerCore.Category
    let rows: [SmartCleanRow]

    var id: CleanerCore.Category { category }

    var bytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }

    /// Rows that have a checkbox.
    var selectableRows: [SmartCleanRow] { rows.filter(\.isSelectable) }
}

/// How far one category is while a scan runs.
struct CategoryProgress: Identifiable {
    let category: CleanerCore.Category
    let totalRules: Int
    let finishedRules: Int
    /// Allocated bytes of the rules that have finished.
    let bytes: Int64

    var id: CleanerCore.Category { category }

    var isDone: Bool { finishedRules >= totalRules }
}

extension CleanerCore.Category {
    /// Plain name for section headers.
    var smartCleanTitle: String {
        switch self {
        case .caches: "Caches"
        case .logs: "Logs and crash reports"
        case .trash: "Trash"
        case .browsers: "Browsers"
        case .apps: "App caches"
        case .developer: "Developer"
        case .mail: "Mail and Messages"
        case .ios: "iPhone and iPad"
        case .installers: "Installers and downloads"
        case .system: "System Data"
        }
    }
}

extension CleanReport {
    /// Items that were moved or deleted.
    var removedCount: Int { items.filter(\.didRemove).count }

    var movedCount: Int { items.filter { if case .moved = $0.outcome { true } else { false } }.count }

    var deletedCount: Int { items.filter { if case .deleted = $0.outcome { true } else { false } }.count }

    var skippedItems: [(item: ItemReport, reason: DenyReason)] {
        items.compactMap { item in
            if case .skipped(let reason) = item.outcome { (item, reason) } else { nil }
        }
    }

    var failedItems: [(item: ItemReport, message: String)] {
        items.compactMap { item in
            if case .failed(let message) = item.outcome { (item, message) } else { nil }
        }
    }
}

/// "1 item" or "12 items".
func itemsText(_ count: Int) -> String {
    count == 1 ? "1 item" : "\(count.formatted()) items"
}

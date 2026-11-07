import CleanerCore
import CleanerScanner
import Foundation

/// Everything one System Data load found, ready to draw.
nonisolated struct SystemDataReport {
    /// Rows in page order: by section, then in catalog order.
    let rows: [SystemDataRow]
    /// Bytes the Data volume uses, or `nil` when macOS did not say.
    let dataVolumeUsed: Int64?
    /// Sum of every measured size that sits on the Data volume.
    let measuredBytes: Int64
    /// Used space that no measurement explains. Never negative. `nil` when ``dataVolumeUsed`` is unknown.
    let unexplainedBytes: Int64?

    /// Rows of one section, in page order.
    func rows(in section: SystemDataSection) -> [SystemDataRow] {
        rows.filter { $0.section == section }
    }

    /// The line under the page title.
    var summary: String {
        guard let used = dataVolumeUsed, let unexplained = unexplainedBytes else {
            return "TruongCleaner could not read how much space the Data volume uses."
        }
        let accounted = ByteFormatter.string(min(measuredBytes, used))
        let total = ByteFormatter.string(used)
        if unexplained == 0 {
            return "\(accounted) of \(total) used. Our measurements cover all used space."
        }
        return "\(accounted) of \(total) used is accounted for. \(ByteFormatter.string(unexplained)) is unexplained."
    }
}

/// The raw answers one load collects, before they become rows.
nonisolated struct SystemDataInputs {
    /// Enabled Info rules, in catalog order.
    var rules: [Rule]
    /// Scan results by rule ID, for the rules that have a folder to measure.
    var results: [String: RuleResult]
    var volume: VolumeInfo
    var snapshots: Result<[LocalSnapshot], ProbeError>
    var swap: SwapUsage?
    var runtimes: Result<[SimulatorRuntime], ProbeError>
}

/// Turns scan results and probe answers into the rows of the System Data page. Pure: no I/O.
nonisolated enum SystemDataBuilder {
    static let unexplainedID = "system.unexplained"

    /// Why the Unexplained number is a rough one.
    static let imprecisionNote =
        "APFS clones and snapshots make these sums imprecise, and macOS does not report the breakdown."

    /// Builds the report.
    ///
    /// Unexplained is the Data volume's used space minus every measured size that sits on that volume,
    /// clamped at zero. Swap is not subtracted, because swap files live on the separate VM volume. Snapshots
    /// have no size.
    static func build(_ inputs: SystemDataInputs) -> SystemDataReport {
        var rows: [SystemDataRow] = []
        for rule in inputs.rules where rule.tier == .info {
            switch rule.match {
            case .computed(let key): rows.append(computedRow(rule, key: key, inputs: inputs))
            case .measureOnly: rows.append(measuredRow(rule, result: inputs.results[rule.id]))
            case .children, .glob, .files, .ownerCommand: continue
            }
        }
        rows.append(simulatorRuntimesRow(inputs.runtimes))
        rows = rows.enumerated()
            .sorted { ($0.element.section.rawValue, $0.offset) < ($1.element.section.rawValue, $1.offset) }
            .map(\.element)

        let measured = rows.filter(\.countsTowardUsed).reduce(Int64(0)) { $0 + ($1.value.countedBytes ?? 0) }
        let used = inputs.volume.dataVolumeUsed
        let unexplained = used.map { max(0, $0 - measured) }

        if let index = rows.firstIndex(where: { $0.id == unexplainedID }) {
            var row = rows[index]
            switch unexplained {
            case nil:
                row.value = .unknown
                row.note = "macOS did not report how much space the Data volume uses."
            case 0?:
                row.value = .size(0)
                row.note = "Our measurements cover all used space. " + imprecisionNote
            case let bytes?:
                row.value = .size(bytes)
                row.note = imprecisionNote
            }
            rows[index] = row
        }
        return SystemDataReport(
            rows: rows, dataVolumeUsed: used, measuredBytes: measured, unexplainedBytes: unexplained
        )
    }

    // MARK: Rows

    private static func row(for rule: Rule, value: SystemDataValue, counts: Bool) -> SystemDataRow {
        let look = SystemDataRow.look(ruleID: rule.id)
        return SystemDataRow(
            id: rule.id,
            section: .section(for: rule.category),
            symbol: look.symbol,
            color: look.color,
            title: String(localized: rule.title),
            explain: String(localized: rule.explain),
            value: value,
            settingsURL: rule.settingsURL,
            command: rule.sanctionedCommand,
            countsTowardUsed: counts
        )
    }

    private static func computedRow(_ rule: Rule, key: String, inputs: SystemDataInputs) -> SystemDataRow {
        switch key {
        case "system.purgeable":
            let value: SystemDataValue = inputs.volume.total > 0 ? .size(inputs.volume.purgeable) : .unknown
            return row(for: rule, value: value, counts: true)
        case "system.snapshots":
            var snapshotRow = row(for: rule, value: .unknown, counts: false)
            if case .success(let list) = inputs.snapshots {
                snapshotRow.value = list.isEmpty ? .text("None") : .text("\(list.count) · size unknown")
                if !list.isEmpty { snapshotRow.snapshots = sortedNewestFirst(list) }
            }
            return snapshotRow
        case "system.swap":
            // Swap files live on the VM volume, so they do not count against the Data volume.
            let value: SystemDataValue = inputs.swap.map { .size($0.used) } ?? .unknown
            return row(for: rule, value: value, counts: false)
        case "system.rosetta":
            return row(for: rule, value: .macOSOnly, counts: false)
        case unexplainedID:
            // Filled in by `build` once every other size is known.
            return row(for: rule, value: .unknown, counts: false)
        default:
            return row(for: rule, value: .unknown, counts: false)
        }
    }

    /// A folder size, with `EPERM` as "needs access" and never as zero.
    private static func measuredRow(_ rule: Rule, result: RuleResult?) -> SystemDataRow {
        guard let result else { return row(for: rule, value: .unknown, counts: false) }
        let bytes = result.measuredBytes
        let value: SystemDataValue
        if !result.needsAccess.isEmpty {
            if bytes > 0 {
                value = .atLeast(bytes)
            } else {
                value = rule.access == .root ? .macOSOnly : .needsAccess
            }
        } else if result.partial {
            value = bytes > 0 ? .atLeast(bytes) : .unknown
        } else if bytes == 0, !result.missingRoots.isEmpty {
            value = .text("Not found")
        } else {
            value = .size(bytes)
        }
        return row(for: rule, value: value, counts: true)
    }

    /// The total of installed simulator runtimes. It has no catalog rule, so the row is built here.
    private static func simulatorRuntimesRow(_ result: Result<[SimulatorRuntime], ProbeError>) -> SystemDataRow {
        let value: SystemDataValue
        switch result {
        case .success(let runtimes):
            let sizes = runtimes.compactMap(\.sizeBytes)
            let total = sizes.reduce(0, +)
            if runtimes.isEmpty {
                value = .text("None")
            } else if sizes.count == runtimes.count {
                value = .size(total)
            } else {
                value = sizes.isEmpty ? .unknown : .atLeast(total)
            }
        case .failure(.toolMissing):
            value = .text("Not found")
        case .failure:
            value = .unknown
        }
        let look = SystemDataRow.look(ruleID: SystemDataRow.simulatorRuntimesID)
        return SystemDataRow(
            id: SystemDataRow.simulatorRuntimesID,
            section: .developer,
            symbol: look.symbol,
            color: look.color,
            title: "Simulator runtimes",
            explain: """
                Operating systems that Xcode downloaded for its simulators. \
                To remove one, open Xcode, then Settings > Components. Xcode can download it again.
                """,
            value: value,
            settingsURL: nil,
            command: nil,
            countsTowardUsed: true
        )
    }

    private static func sortedNewestFirst(_ snapshots: [LocalSnapshot]) -> [LocalSnapshot] {
        snapshots.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

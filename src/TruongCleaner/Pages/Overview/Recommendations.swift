import CleanerCore
import SwiftUI

/// One line in the Overview's Recommendations group: what was found and the button that goes to it.
struct Recommendation: Identifiable {
    /// What the button does.
    enum Action {
        /// Switches to a page.
        case open(Page)
        /// Starts a Smart Clean scan and switches to Smart Clean. The user pressed the button, so this is
        /// never automatic.
        case startSmartClean
    }

    let id: String
    let symbol: String
    let color: Color
    /// The sentence shown.
    let text: String
    /// The same sentence with sizes written out for VoiceOver ("12.4 gigabytes").
    let spokenText: String
    let buttonTitle: String
    /// What the button is about, for VoiceOver ("Review Smart Clean results").
    let buttonLabel: String
    let action: Action
}

/// Chooses the recommendations from what has already been measured. Reads state only: it never starts a
/// scan, so the Overview stays quiet until the user asks (`docs/UI.md` §4.1).
@MainActor
enum RecommendationBuilder {
    /// Rule IDs the builder looks for.
    private static let iosBackupsRuleID = "ios.backups"

    /// Builds the rows in display order: Smart Clean, largest developer item, iOS backups, snapshots.
    ///
    /// - Parameters:
    ///   - smartClean: The Smart Clean model whose results are summarized.
    ///   - snapshots: What `tmutil` listed, or `nil` while the Overview has not loaded.
    static func build(smartClean: SmartCleanModel, snapshots: OverviewData.SnapshotSummary?) -> [Recommendation] {
        var rows: [Recommendation] = []

        switch smartClean.state {
        case .results:
            rows.append(contentsOf: fromResults(smartClean))
        case .scanning:
            rows.append(Recommendation(
                id: "smartClean.scanning",
                symbol: Page.smartClean.symbol,
                color: Page.smartClean.color,
                text: "Smart Clean is scanning…",
                spokenText: "Smart Clean is scanning",
                buttonTitle: "Show",
                buttonLabel: "Show Smart Clean",
                action: .open(.smartClean)
            ))
        case .cleaning:
            rows.append(Recommendation(
                id: "smartClean.cleaning",
                symbol: Page.smartClean.symbol,
                color: Page.smartClean.color,
                text: "Smart Clean is cleaning…",
                spokenText: "Smart Clean is cleaning",
                buttonTitle: "Show",
                buttonLabel: "Show Smart Clean",
                action: .open(.smartClean)
            ))
        case .idle, .finished:
            // Nothing measured, or the results are out of date after a clean.
            rows.append(Recommendation(
                id: "smartClean.scan",
                symbol: Page.smartClean.symbol,
                color: Page.smartClean.color,
                text: "Scan to see what can be freed",
                spokenText: "Scan to see what can be freed",
                buttonTitle: "Scan",
                buttonLabel: "Scan with Smart Clean",
                action: .startSmartClean
            ))
        }

        if case .count(let count)? = snapshots, count > 0 {
            let text = count == 1
                ? "Time Machine keeps 1 local snapshot on this Mac"
                : "Time Machine keeps \(count.formatted()) local snapshots on this Mac"
            rows.append(Recommendation(
                id: "snapshots",
                symbol: Page.systemData.symbol,
                color: Page.systemData.color,
                text: text,
                spokenText: text,
                buttonTitle: "Learn More…",
                buttonLabel: "Learn more about local snapshots",
                action: .open(.systemData)
            ))
        }
        return rows
    }

    /// Rows for a finished Smart Clean scan.
    private static func fromResults(_ smartClean: SmartCleanModel) -> [Recommendation] {
        let all = smartClean.sections.flatMap(\.rows).filter(\.isSelectable)
        var rows: [Recommendation] = []

        // Safe items are the ones Smart Clean selects by default, so this matches its Clean button.
        let safeBytes = all.filter { $0.rule.tier == .safe }.reduce(Int64(0)) { $0 + $1.bytes }
        if safeBytes > 0 {
            rows.append(Recommendation(
                id: "smartClean.free",
                symbol: Page.smartClean.symbol,
                color: Page.smartClean.color,
                text: "Smart Clean can free about \(ByteFormatter.string(safeBytes))",
                spokenText: "Smart Clean can free about \(SpokenSize.string(safeBytes))",
                buttonTitle: "Review…",
                buttonLabel: "Review Smart Clean results",
                action: .open(.smartClean)
            ))
        }

        if let largest = all.filter({ $0.rule.category == .developer && $0.bytes > 0 })
            .max(by: { $0.bytes < $1.bytes }) {
            let title = String(localized: largest.rule.title)
            rows.append(Recommendation(
                id: "developer.largest",
                symbol: Page.developer.symbol,
                color: Page.developer.color,
                text: "\(title) uses \(ByteFormatter.string(largest.bytes))",
                spokenText: "\(title) uses \(SpokenSize.string(largest.bytes))",
                buttonTitle: "Review…",
                buttonLabel: "Review \(title)",
                // TODO(4.5): open `.developer` once the Developer page exists. Smart Clean lists the same item.
                action: .open(.smartClean)
            ))
        }

        if let backups = all.first(where: { $0.rule.id == iosBackupsRuleID && $0.bytes > 0 }) {
            let count = backups.result.findings.count
            let size = ByteFormatter.string(backups.bytes)
            let spoken = SpokenSize.string(backups.bytes)
            let subject = count == 1 ? "1 iPhone or iPad backup uses" : "\(count.formatted()) iPhone or iPad backups use"
            rows.append(Recommendation(
                id: "ios.backups",
                symbol: "iphone",
                color: .teal,
                text: "\(subject) \(size)",
                spokenText: "\(subject) \(spoken)",
                buttonTitle: "Review…",
                buttonLabel: "Review iPhone and iPad backups",
                action: .open(.smartClean)
            ))
        }

        if rows.isEmpty {
            rows.append(Recommendation(
                id: "smartClean.nothing",
                symbol: Page.smartClean.symbol,
                color: Page.smartClean.color,
                text: "Smart Clean found nothing to remove",
                spokenText: "Smart Clean found nothing to remove",
                buttonTitle: "Scan Again",
                buttonLabel: "Scan again with Smart Clean",
                action: .startSmartClean
            ))
        }
        return rows
    }
}

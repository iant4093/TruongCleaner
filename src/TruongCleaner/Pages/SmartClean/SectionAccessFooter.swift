import CleanerScanner
import SwiftUI

/// The one "needs access" line under a section's last row, shown when any row in the section could not
/// open some of its folders. The rows themselves carry the "Needs access" badge or an unknown size.
struct SectionAccessFooter: View {
    let rows: [SmartCleanRow]
    let access: AccessState

    var body: some View {
        if let kind = Self.kind(for: rows, access: access) {
            NeedsAccessRow(kind: kind, openPrivacySettings: SmartCleanActions.openPrivacySettings)
        }
    }

    /// What to tell the user, or `nil` when no row needs access. Full Disk Access can only help a row that
    /// is not root-only.
    static func kind(for rows: [SmartCleanRow], access: AccessState) -> NeedsAccessRow.Kind? {
        let needing = rows.filter(\.needsAccess)
        guard !needing.isEmpty else { return nil }
        if needing.allSatisfy({ $0.rule.access == .root }) { return .administratorOnly }
        return access == .granted ? .refusedByMacOS : .fullDiskAccess
    }
}

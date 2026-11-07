import CleanerCore
import CleanerScanner
import SwiftUI

/// Turns a ``CategoryTotals`` into the parts of the Overview bar.
///
/// Sizes are the bytes each category holds on its own (`privateBytes`): data that APFS clones share
/// between two copies is counted in neither copy. The sum of the parts therefore never exceeds what the
/// disk uses, and the shared part falls into "System Data", the remainder.
enum CategoryBreakdown {
    /// One bar part and the categories it adds up.
    struct Part {
        let label: String
        let categories: [StorageCategory]
        let color: Color
    }

    /// Bar parts in drawing order. Every ``StorageCategory`` is in exactly one part.
    static let parts: [Part] = [
        Part(label: "Applications", categories: [.applications], color: .blue),
        Part(label: "Documents & files", categories: [.documents, .downloads, .desktop], color: .yellow),
        Part(label: "Photos & media", categories: [.pictures, .movies, .music], color: .pink),
        Part(label: "iCloud Drive", categories: [.icloud], color: .cyan),
        Part(label: "Developer", categories: [.developer], color: .indigo),
        Part(label: "Caches", categories: [.libraryCaches], color: .mint),
        Part(label: "iOS backups", categories: [.iosBackups], color: .green),
        Part(label: "Mail & Messages", categories: [.mail, .messages], color: .purple),
        Part(label: "Trash", categories: [.trash], color: .red),
        Part(label: "Other in your home", categories: [.libraryOther, .otherHome], color: .brown),
        Part(label: "Other users", categories: [.otherUsers], color: .orange.opacity(0.6)),
    ]

    /// Label of the remainder part.
    nonisolated static let systemDataLabel = "System Data"

    /// Exclusive bytes of every category together. This is what System Data and Unexplained subtract.
    nonisolated static func measuredBytes(_ totals: CategoryTotals) -> Int64 {
        totals.totalPrivateBytes
    }

    /// Exclusive bytes of one category.
    nonisolated static func bytes(_ category: StorageCategory, in totals: CategoryTotals) -> Int64 {
        totals.privateBytes[category] ?? 0
    }

    /// The bar parts for a measurement. Parts of zero bytes are kept; the bar skips them.
    static func segments(_ totals: CategoryTotals) -> [StorageSegment] {
        parts.map { part in
            StorageSegment(
                label: part.label,
                bytes: part.categories.reduce(Int64(0)) { $0 + bytes($1, in: totals) },
                color: part.color
            )
        }
    }

    /// What is left of the Data volume after purgeable space and the measured categories. Never negative.
    nonisolated static func systemData(dataUsed: Int64, purgeable: Int64, totals: CategoryTotals) -> Int64 {
        max(0, dataUsed - purgeable - measuredBytes(totals))
    }
}

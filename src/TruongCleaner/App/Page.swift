import SwiftUI

/// Sidebar groups from `docs/UI.md` §3. The first group has no heading.
enum PageGroup: CaseIterable, Identifiable {
    case top, clean, explore, manage

    var id: Self { self }

    /// Heading shown above the group, or `nil` for the top group.
    var title: String? {
        switch self {
        case .top: nil
        case .clean: "Clean"
        case .explore: "Explore"
        case .manage: "Manage"
        }
    }
}

/// The nine sidebar pages from `docs/UI.md` §3.
enum Page: String, CaseIterable, Identifiable {
    case overview, smartClean, systemData, developer, largeFiles
    case spaceLens, applications
    case trash, history

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .smartClean: "Smart Clean"
        case .systemData: "System Data"
        case .developer: "Developer"
        case .largeFiles: "Large & Old Files"
        case .spaceLens: "Space Lens"
        case .applications: "Applications"
        case .trash: "Trash"
        case .history: "History"
        }
    }

    /// One line shown under the title in the page header.
    var subtitle: String {
        switch self {
        case .overview: "See where your disk space went."
        case .smartClean: "Find what is safe to remove."
        case .systemData: "Understand what macOS counts as System Data."
        case .developer: "Free Xcode, simulator and package manager space."
        case .largeFiles: "Find big files you have not opened in a while."
        case .spaceLens: "Explore a folder by size."
        case .applications: "See what your apps use."
        case .trash: "Review and empty the Trash."
        case .history: "See what each clean did, and put items back."
        }
    }

    /// SF Symbol name (SF Symbols 7).
    var symbol: String {
        switch self {
        case .overview: "internaldrive.fill"
        case .smartClean: "sparkles"
        case .systemData: "gearshape.2.fill"
        case .developer: "hammer.fill"
        case .largeFiles: "doc.text.magnifyingglass"
        case .spaceLens: "chart.pie.fill"
        case .applications: "square.grid.2x2.fill"
        case .trash: "trash.fill"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// Icon tile color.
    var color: Color {
        switch self {
        case .overview, .systemData, .trash: .gray
        case .smartClean, .applications: .blue
        case .developer: .indigo
        case .largeFiles: .orange
        case .spaceLens: .purple
        case .history: .teal
        }
    }

    var group: PageGroup {
        switch self {
        case .overview: .top
        case .smartClean, .systemData, .developer, .largeFiles: .clean
        case .spaceLens, .applications: .explore
        case .trash, .history: .manage
        }
    }

    /// Plan wave that builds the real page (`docs/PLAN.md` §8).
    var builtInWave: Int {
        switch self {
        case .overview: 2
        case .smartClean, .trash, .history: 3
        case .systemData, .developer: 4
        case .largeFiles, .spaceLens: 5
        case .applications: 6
        }
    }
}

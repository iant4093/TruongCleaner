import SwiftUI

/// Sidebar pages from docs/UI.md §3.
enum Page: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview, smartClean, systemData, developer, largeFiles
    case spaceLens, applications
    case trash, history

    var id: String { rawValue }

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

    /// Fake trailing size badge, as shown after a scan.
    var badge: String? {
        switch self {
        case .smartClean: "22.4 GB"
        case .systemData: "23.4 GB"
        case .developer: "16.3 GB"
        case .largeFiles: "48.1 GB"
        case .trash: "1.8 GB"
        default: nil
        }
    }
}

struct PageSection: Identifiable {
    let title: String?
    let pages: [Page]
    var id: String { title ?? "top" }

    static let all: [PageSection] = [
        .init(title: nil, pages: [.overview]),
        .init(title: "Clean", pages: [.smartClean, .systemData, .developer, .largeFiles]),
        .init(title: "Explore", pages: [.spaceLens, .applications]),
        .init(title: "Manage", pages: [.trash, .history]),
    ]
}

struct RootView: View {
    @State private var selection: Page? = .overview
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, searchText: searchText)
                .navigationSplitViewColumnWidth(min: 215, ideal: 230, max: 260)
        } detail: {
            DetailView(page: selection ?? .overview)
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
        .frame(minWidth: 760, minHeight: 520)
        .task {
            await SnapshotRunner.runIfRequested()
        }
    }
}

struct SidebarView: View {
    @Binding var selection: Page?
    let searchText: String

    var body: some View {
        List(selection: $selection) {
            ForEach(PageSection.all) { section in
                let rows = section.pages.filter(matches)
                if !rows.isEmpty {
                    if let title = section.title {
                        Section(title) { sidebarRows(rows) }
                    } else {
                        sidebarRows(rows)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func matches(_ page: Page) -> Bool {
        searchText.isEmpty || page.title.localizedCaseInsensitiveContains(searchText)
    }

    private func sidebarRows(_ rows: [Page]) -> some View {
        ForEach(rows) { page in
            Label {
                Text(page.title)
            } icon: {
                IconTile(symbol: page.symbol, color: page.color)
            }
            .badge(page.badge.map { Text($0) })
            .tag(page)
        }
    }
}

struct DetailView: View {
    let page: Page

    var body: some View {
        content
            .navigationTitle(page.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {} label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button {} label: {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("r")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .overview: OverviewPage()
        case .smartClean: SmartCleanPage()
        case .systemData: SystemDataPage()
        default:
            ContentUnavailableView(
                page.title,
                systemImage: page.symbol,
                description: Text("This page is not part of the S5 prototype.")
            )
        }
    }
}

import SwiftUI

/// The main window: sidebar of pages and a detail column.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: selection, searchText: searchText)
                .navigationSplitViewColumnWidth(min: 215, ideal: 230, max: 260)
        } detail: {
            DetailView(page: model.selection)
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
        .frame(minWidth: 760, minHeight: 520)
    }

    /// `List(selection:)` needs an optional binding. A cleared selection is ignored.
    private var selection: Binding<Page?> {
        Binding(
            get: { model.selection },
            set: { newValue in
                if let newValue { model.selection = newValue }
            }
        )
    }
}

private struct SidebarView: View {
    @Binding var selection: Page?
    let searchText: String

    var body: some View {
        List(selection: $selection) {
            ForEach(PageGroup.allCases) { group in
                let rows = Page.allCases.filter { $0.group == group && matches($0) }
                if !rows.isEmpty {
                    if let title = group.title {
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
            .tag(page)
        }
    }
}

private struct DetailView: View {
    let page: Page

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: page.symbol, color: page.color, title: page.title, subtitle: page.subtitle)
                .padding(.horizontal, 24)
                .padding(.top, 20)
            ContentUnavailableView(
                page.title,
                systemImage: page.symbol,
                description: Text("This page is built in Wave \(page.builtInWave).")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(page.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {} label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut("r")
                .disabled(true)
            }
        }
    }
}

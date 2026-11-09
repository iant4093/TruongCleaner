import AppKit
import CleanerCore
import CleanerScanner
import SwiftUI

/// Applications: the installed apps with their sizes, and the uninstaller for the selected one.
struct ApplicationsPage: View {
    @Bindable var model: ApplicationsModel
    @State private var searchText = ""
    @State private var showConfirm = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                symbol: Page.applications.symbol,
                color: Page.applications.color,
                title: Page.applications.title,
                subtitle: "Remove an app together with the files it left in your Library."
            )
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.hasLoaded, !model.inventoryIsComplete {
                Label(
                    "The list of apps could not be read in full. Files that match an app by name only are not offered.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            sortBar
            list
        }
        .searchable(text: $searchText, prompt: "Search Applications")
        .inspector(isPresented: inspectorBinding) {
            ApplicationDetail(model: model) { showConfirm = true }
                .inspectorColumnWidth(min: 340, ideal: 400, max: 560)
        }
        .overlay { dropHint }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { await model.handleDrop(urls) }
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .task { model.loadIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshRunningState()
        }
        .confirmationDialog(
            confirmTitle, isPresented: $showConfirm, titleVisibility: .visible
        ) {
            Button("Move to Trash") { model.clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .sheet(isPresented: resultBinding) {
            if let report = model.finishedReport {
                UninstallResultSheet(model: model, report: report)
            }
        }
    }

    // MARK: List

    private var sortBar: some View {
        HStack {
            Spacer()
            Picker("Sort by", selection: $model.sort) {
                ForEach(ApplicationSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityHint("Orders the list of apps")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
    }

    private var list: some View {
        List(selection: selection) {
            ForEach(filteredRows) { row in
                ApplicationRowView(row: row)
                    .tag(row.id)
                    .selectionDisabled(row.refusal != nil)
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.isLoading && model.rows.isEmpty {
                ProgressView("Looking for apps…")
            } else if model.hasLoaded && filteredRows.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "No Apps Found", systemImage: "square.grid.2x2",
                        description: Text("Nothing was found in /Applications or ~/Applications."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .disabled(model.isCleaning)
    }

    private var filteredRows: [ApplicationRow] {
        let rows = model.sortedRows
        guard !searchText.isEmpty else { return rows }
        return rows.filter {
            $0.facts.title.localizedCaseInsensitiveContains(searchText)
                || ($0.facts.bundleID?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { model.selectedID }, set: { model.select($0) })
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { model.selectedID != nil || model.isCleaning },
            set: { if !$0 { model.select(nil) } }
        )
    }

    private var resultBinding: Binding<Bool> {
        Binding(
            get: { model.finishedReport != nil },
            set: { if !$0 { model.dismissResult() } }
        )
    }

    // MARK: Drop

    @ViewBuilder
    private var dropHint: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: Confirmation

    private var confirmTitle: String {
        "Uninstall \(model.selectedRow?.facts.title ?? "this app")?"
    }

    private var confirmMessage: String {
        let size = ByteFormatter.string(model.selectedBytes)
        let related = model.checkedLeftovers.count
        let files = related == 0 ? "" : " and \(related == 1 ? "1 related item" : "\(related.formatted()) related items")"
        return "Moves the app\(files), about \(size), to the Trash. You can put them back from the result."
    }
}

/// One app in the list: icon, name, version, and its size (or the reason it cannot be removed).
private struct ApplicationRowView: View {
    let row: ApplicationRow

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(url: row.facts.url, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.facts.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let refusal = row.refusal, let badge = badge(for: refusal) {
                Text(badge)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            sizeView
        }
        .opacity(row.refusal == nil ? 1 : 0.6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Reveal in Finder") { SmartCleanActions.reveal(row.facts.url) }
        }
    }

    private var subtitle: String {
        if let refusal = row.refusal { return refusal.message }
        return row.facts.version.map { "Version \($0)" } ?? ""
    }

    private func badge(for refusal: UninstallRefusal) -> String? {
        if refusal.isApple { return "Apple" }
        if refusal == .running { return "Running" }
        return nil
    }

    @ViewBuilder
    private var sizeView: some View {
        if let size = row.size {
            if let bytes = size.allocatedBytes {
                SizeText(bytes: bytes, isEstimate: size.isPartial)
                    .foregroundStyle(.secondary)
            } else {
                SizeText(bytes: 0, isUnknown: true)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Measuring size")
        }
    }
}

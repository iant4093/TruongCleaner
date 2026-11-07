import CleanerCore
import CleanerScanner
import QuickLook
import SwiftUI

/// Large & Old Files (`docs/UI.md` §4.5). Read-only: reveal, preview and copy paths. Nothing is removed here.
struct LargeFilesPage: View {
    @Bindable var model: LargeFilesModel
    @State private var quickLookURL: URL?
    @State private var quickLookItems: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            controls
                .frame(maxHeight: model.outcome == nil ? nil : 300)
            if let outcome = model.outcome, outcome.failureMessage == nil {
                Divider()
                if model.rows.isEmpty {
                    emptyResults
                } else {
                    resultsTable
                    footer(outcome)
                }
            }
        }
        .quickLookPreview($quickLookURL, in: quickLookItems)
    }

    // MARK: Controls

    private var controls: some View {
        Form {
            Section {
                PageHeader(
                    symbol: Page.largeFiles.symbol,
                    color: Page.largeFiles.color,
                    title: Page.largeFiles.title,
                    subtitle: "Find big files you have not changed in a while."
                )
            }

            Section("Look in") {
                ForEach(model.folders, id: \.self) { folder in
                    folderRow(folder)
                }
                Button {
                    model.addFolders(LargeFilesActions.chooseFolders())
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .disabled(model.isSearching)
                .accessibilityLabel("Add folder to search")
            }

            Section {
                Picker("Larger than", selection: $model.minimumSize) {
                    ForEach(MinimumFileSize.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.isSearching)
                Picker("Not modified in", selection: $model.untouchedPeriod) {
                    ForEach(UntouchedPeriod.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.isSearching)
                searchRow
            }

            if let outcome = model.outcome {
                notices(outcome)
            }
        }
        .formStyle(.grouped)
    }

    private func folderRow(_ folder: URL) -> some View {
        HStack {
            Label(LargeFileRow.abbreviate(folder.path), systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                model.removeFolder(folder)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(model.isSearching)
            .accessibilityLabel("Remove \(folder.lastPathComponent) from the list")
            .help("Remove from the list. The folder itself is not changed.")
        }
    }

    private var searchRow: some View {
        HStack {
            switch model.phase {
            case .idle:
                Spacer()
                Button("Find Large Files") { model.find() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.folders.isEmpty)
            case .searching(let filesChecked):
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching")
                Text("\(filesChecked.formatted()) files checked")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Stop") { model.stop() }
            }
        }
    }

    @ViewBuilder
    private func notices(_ outcome: LargeFilesModel.Outcome) -> some View {
        if let message = outcome.failureMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
            }
        }
        if !outcome.needsAccess.isEmpty {
            Section {
                Label(
                    "^[\(outcome.needsAccess.count) folder](inflect: true) could not be read. "
                        + "They may need Full Disk Access, so their files are not in this list.",
                    systemImage: "lock.fill"
                )
                DisclosureGroup("Show folders") {
                    ForEach(outcome.needsAccess.prefix(10), id: \.self) { url in
                        Text(LargeFileRow.abbreviate(url.path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if outcome.needsAccess.count > 10 {
                        Text("and \(outcome.needsAccess.count - 10) more")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if !outcome.skippedFolders.isEmpty {
            Section {
                Label(
                    "^[\(outcome.skippedFolders.count) folder](inflect: true) in the list was skipped "
                        + "because it is missing or is not a folder.",
                    systemImage: "questionmark.folder"
                )
            }
        }
    }

    // MARK: Results

    private var emptyResults: some View {
        ContentUnavailableView(
            "No Large Files Found",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Nothing in these folders matches the size and date you chose.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsTable: some View {
        Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                Label {
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    LargeFileIcon(path: row.url.path)
                }
            }
            .width(min: 140, ideal: 220)

            TableColumn("Kind", value: \.kind, comparator: .localizedStandard) { row in
                Text(row.kind).lineLimit(1)
            }
            .width(min: 70, ideal: 110)

            TableColumn("Size", value: \.allocatedBytes) { row in
                Text(ByteFormatter.string(row.allocatedBytes)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            .alignment(.numeric)

            TableColumn("Modified", value: \.modifiedSort) { row in
                Text(row.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unknown")
            }
            .width(min: 90, ideal: 110)

            TableColumn("Location", value: \.location, comparator: .localizedStandard) { row in
                Text(row.location)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .help(row.url.path)
            }
            .width(min: 120, ideal: 220)
        }
        .contextMenu(forSelectionType: EntryID.self) { ids in
            if !ids.isEmpty {
                Button("Reveal in Finder") { LargeFilesActions.reveal(model.urls(for: ids)) }
                Button("Quick Look") { showQuickLook(ids) }
                Button("Copy Path") { LargeFilesActions.copyPaths(model.urls(for: ids)) }
            }
        }
        .onKeyPress(.space) {
            guard !model.selection.isEmpty else { return .ignored }
            showQuickLook(model.selection)
            return .handled
        }
        .accessibilityLabel("Large files")
    }

    private func footer(_ outcome: LargeFilesModel.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("^[\(model.rows.count) file](inflect: true), about \(ByteFormatter.string(model.totalBytes)) on disk")
                if !model.selection.isEmpty {
                    Text("· \(model.selection.count) selected")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal in Finder") { LargeFilesActions.reveal(model.urls(for: model.selection)) }
                    .disabled(model.selection.isEmpty)
                Button("Quick Look") { showQuickLook(model.selection) }
                    .keyboardShortcut("y", modifiers: .command)
                    .disabled(model.selection.isEmpty)
            }
            if outcome.partial {
                Text("The search was stopped early. These are the files found so far.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if outcome.mayBeMissingFiles {
                Text("Only the largest matches are shown. Raise the minimum size or choose fewer folders to see others.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func showQuickLook(_ ids: Set<EntryID>) {
        let urls = model.urls(for: ids)
        guard let first = urls.first else { return }
        quickLookItems = urls
        quickLookURL = first
    }
}

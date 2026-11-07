import AppKit
import enum CleanerCore.ByteFormatter
import QuickLook
import SwiftUI

/// Explore a folder by size (`docs/UI.md` §4.6). Read-only: nothing here deletes.
struct SpaceLensPage: View {
    let model: SpaceLensModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                symbol: Page.spaceLens.symbol,
                color: Page.spaceLens.color,
                title: Page.spaceLens.title,
                subtitle: subtitle
            )
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 10)

            BreadcrumbBar(model: model)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footnote
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Choose Folder…", systemImage: "folder") { chooseFolder() }
                    .help("Choose a folder to explore")
            }
        }
    }

    // MARK: Header and footer text

    private var subtitle: String {
        switch model.state {
        case .ready(let tree):
            "“\(tree.root.name)” uses about \(ByteFormatter.string(tree.root.bytes)) on disk."
        default:
            Page.spaceLens.subtitle
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 2) {
            if case .ready(let tree) = model.state, tree.deniedCount > 0 {
                Label(
                    "\(tree.deniedCount) \(tree.deniedCount == 1 ? "folder needs" : "folders need") access. "
                        + "Their size is not in these totals. Full Disk Access lets TruongCleaner read them.",
                    systemImage: "lock.fill"
                )
            }
            Text(
                "Sizes are space used on disk. Files that share storage (APFS clones) are counted in each place."
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView {
                Label("Scan “\(model.current.lastPathComponent)”", systemImage: Page.spaceLens.symbol)
            } description: {
                Text("See which folders and files take the most space.")
            } actions: {
                Button("Scan") { model.scan() }
                    .modifier(ProminentActionButton())
            }
        case .scanning(let status):
            ScanningView(status: status, onStop: model.cancel)
        case .failed(let message):
            ContentUnavailableView {
                Label("Could Not Scan", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.scan() }
            }
        case .ready(let tree):
            LensResults(model: model, tree: tree)
        }
    }

    // MARK: Choosing a folder

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to explore by size."
        panel.directoryURL = model.root
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            // A link picked in the panel stands for the folder it points to. The walker never follows links itself.
            model.choose(url.resolvingSymlinksInPath())
        }
    }
}

// MARK: - Breadcrumb

/// The folders from the chosen root down to the one on screen, separated by chevrons.
private struct BreadcrumbBar: View {
    let model: SpaceLensModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.path.enumerated()), id: \.offset) { index, url in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    crumb(url, index: index, isLast: index == model.path.count - 1)
                }
            }
        }
        .accessibilityLabel("Folder path")
    }

    @ViewBuilder
    private func crumb(_ url: URL, index: Int, isLast: Bool) -> some View {
        let name = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        if isLast {
            Text(name).fontWeight(.semibold)
        } else {
            Button(name) { model.navigate(toBreadcrumb: index) }
                .buttonStyle(.borderless)
                .accessibilityHint("Goes back to this folder")
        }
    }
}

// MARK: - Scanning

private struct ScanningView: View {
    let status: SpaceLensModel.ScanStatus
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .accessibilityLabel("Scanning")
            Text("Scanning…")
                .font(.headline)
            Text("\(status.files.formatted()) files · about \(ByteFormatter.string(status.bytes)) so far")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let path = status.currentPath {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            Button("Stop", action: onStop)
        }
        .padding()
    }
}

// MARK: - Results

/// The chart and the list for one scanned folder. The list goes below the chart when the window is narrow.
private struct LensResults: View {
    let model: SpaceLensModel
    let tree: LensTree

    var body: some View {
        if tree.root.children.isEmpty {
            ContentUnavailableView(
                "Nothing to Show",
                systemImage: "folder",
                description: Text("“\(tree.root.name)” has no files that use space, or none that can be read.")
            )
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    chart
                        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    LensList(model: model, tree: tree)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
                }
                .padding(16)
                VStack(spacing: 8) {
                    chart
                        .frame(maxWidth: .infinity, minHeight: 200, idealHeight: 260, maxHeight: 280)
                    LensList(model: model, tree: tree)
                }
                .padding(16)
            }
        }
    }

    private var chart: some View {
        SunburstView(
            tree: tree,
            canGoUp: model.canGoUp,
            onExplore: { node in
                if let url = node.url { model.explore(url) }
            },
            onGoUp: model.goUp
        )
    }
}

// MARK: - List

private struct LensList: View {
    let model: SpaceLensModel
    let tree: LensTree

    @State private var selection: Int?
    @State private var quickLookURL: URL?

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(tree.root.children.enumerated()), id: \.element.id) { index, node in
                LensRow(node: node, rootBytes: tree.root.bytes, paletteIndex: index)
                    .tag(node.id)
                    .contextMenu { menu(for: node) }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            if node.isExplorable, let url = node.url { model.explore(url) }
                        }
                    )
                    .accessibilityActions {
                        if node.isExplorable, let url = node.url {
                            Button("Open Folder") { model.explore(url) }
                        }
                    }
            }
        }
        .listStyle(.inset)
        .quickLookPreview($quickLookURL)
        .onKeyPress(.space) {
            guard let url = selectedNode?.url, selectedNode?.isDenied == false else { return .ignored }
            quickLookURL = url
            return .handled
        }
        .onKeyPress(.return) {
            guard let node = selectedNode, node.isExplorable, let url = node.url else { return .ignored }
            model.explore(url)
            return .handled
        }
        .accessibilityLabel("Items in \(tree.root.name), largest first")
    }

    private var selectedNode: LensNode? {
        tree.root.children.first { $0.id == selection }
    }

    @ViewBuilder
    private func menu(for node: LensNode) -> some View {
        if let url = node.url {
            if node.isExplorable {
                Button("Open Folder") { model.explore(url) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            if !node.isDenied {
                Button("Quick Look") { quickLookURL = url }
            }
        }
    }
}

private struct LensRow: View {
    let node: LensNode
    let rootBytes: Int64
    let paletteIndex: Int

    private static let barWidth: CGFloat = 56

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 0) {
                Text(rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.isDenied {
                    Text("Needs access")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if !node.isDenied {
                sizeBar
                SizeText(bytes: node.bytes)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var rowTitle: String {
        node.kind == .other ? "Other (\(node.itemCount.formatted()) items)" : node.name
    }

    @ViewBuilder
    private var icon: some View {
        if node.isDenied {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .accessibilityLabel("Locked")
        } else if let url = node.url {
            FileIcon(url: url)
        } else {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
    }

    /// Share of the folder, in the slice's color.
    private var sizeBar: some View {
        let share = rootBytes > 0 ? min(1, Double(node.bytes) / Double(rootBytes)) : 0
        let color = SunburstPalette.color(index: node.kind == .other ? nil : paletteIndex, ring: 1)
        return Capsule()
            .fill(.quaternary)
            .frame(width: Self.barWidth, height: 6)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(color)
                    .frame(width: max(2, Self.barWidth * share), height: 6)
            }
            .accessibilityHidden(true)
    }
}

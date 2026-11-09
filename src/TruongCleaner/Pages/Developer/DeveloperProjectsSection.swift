import CleanerCore
import CleanerScanner
import SwiftUI

/// Project folders (`docs/UI.md` §4.4): the folders the user adds, a button that looks for build output
/// inside them, and the results grouped by project. Nothing is ticked until the user ticks it.
struct DeveloperProjectsSection: View {
    /// Build folders listed under one project. The clean still covers every ticked build folder.
    private static let listLimit = 50

    let model: DeveloperModel
    let settings: SettingsStore
    let access: AccessState
    @Binding var showConfirm: Bool

    var body: some View {
        folderSection
        resultSection
    }

    // MARK: Folders

    private var folderSection: some View {
        Section {
            if settings.projectFolders.isEmpty {
                Text("No folders added yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(settings.projectFolders, id: \.self) { folder in
                folderRow(folder)
            }
            HStack {
                Button("Add Folder…", systemImage: "plus") {
                    settings.addProjectFolders(DeveloperActions.chooseProjectFolders())
                }
                Button("Find Build Folders", systemImage: "magnifyingglass") {
                    model.findBuildFolders()
                }
                .disabled(!model.canFindBuildFolders)
                if model.projects.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Searching project folders")
                    Button("Stop") { model.projects.stopScan() }
                }
            }
        } header: {
            Text("Project folders")
        } footer: {
            Text(
                "Finds node_modules, .build, target and similar folders in projects you have not "
                    + "touched for 30 days. Folders that hold a .git folder are left alone."
            )
        }
    }

    private func folderRow(_ folder: URL) -> some View {
        let usable = model.isUsable(folder)
        return HStack {
            Label(folder.path(percentEncoded: false), systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder.path(percentEncoded: false))
            Spacer(minLength: 8)
            if !usable {
                Text("Too broad to search")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                settings.removeProjectFolder(folder)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove from the list")
            .accessibilityLabel("Remove \(folder.lastPathComponent) from project folders")
        }
    }

    // MARK: Results

    @ViewBuilder
    private var resultSection: some View {
        switch model.projects.state {
        case .idle, .scanning:
            EmptyView()
        case .results, .cleaning, .finished:
            let groups = model.projectGroups
            let selection = model.projectSelection()
            Section {
                if let notice = model.projects.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                }
                if model.projects.scanWasPartial {
                    Text("The search stopped early. These are the build folders found so far.")
                        .foregroundStyle(.secondary)
                }
                if groups.isEmpty {
                    Text("No build folders found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    groupRow(group)
                }
                if let row = model.projects.sections.flatMap(\.rows).first, row.needsAccess {
                    NeedsAccessRow(
                        kind: access == .granted ? .refusedByMacOS : .fullDiskAccess,
                        openPrivacySettings: SmartCleanActions.openPrivacySettings)
                }
                if !groups.isEmpty {
                    actionRow(count: selection.count, bytes: selection.confirmation.bytes)
                }
            } header: {
                Text("Build folders found")
            } footer: {
                if !groups.isEmpty {
                    Text("Review items are not ticked. Tick the projects you are done with.")
                }
            }
        }
    }

    private func groupRow(_ group: DeveloperModel.ProjectGroup) -> some View {
        ItemRow(
            icon: ItemRowIcon(symbol: "folder.fill", color: .blue),
            title: group.name,
            explain: subtitle(group),
            size: .bytes(group.bytes)
        )
        .selection(
            Binding(
                get: { model.isSelected(group) },
                set: { model.setSelected($0, for: group) }
            )
        )
        .badge(.review)
        .disclosure {
            ForEach(group.findings.prefix(Self.listLimit)) { finding in
                FindingRow(finding: finding)
            }
            if group.findings.count > Self.listLimit {
                Text("and \((group.findings.count - Self.listLimit).formatted()) more")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(_ group: DeveloperModel.ProjectGroup) -> String {
        let names = Set(group.findings.map { $0.url.lastPathComponent }).sorted().joined(separator: ", ")
        guard let location = group.location else { return names }
        return "\(location.path(percentEncoded: false)) · \(names)"
    }

    private func actionRow(count: Int, bytes: Int64) -> some View {
        HStack {
            Text(CleanBarText.summary(bytes: bytes, itemCount: count, mode: model.projects.deleteMode))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Clean Selected…") { showConfirm = true }
                .disabled(count == 0 || model.isBusy)
                .accessibilityHint("Asks you to confirm before anything is moved")
        }
    }
}

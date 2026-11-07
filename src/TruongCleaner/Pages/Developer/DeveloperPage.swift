import CleanerActions
import CleanerCore
import CleanerScanner
import SwiftUI

/// Developer (`docs/UI.md` §4.4): Xcode, simulators, package managers, Docker and project build folders.
///
/// File rules are cleaned through Smart Clean's models, rows, clean bar, confirmation and result sheet.
/// Rules that a tool carries out itself (Homebrew, Docker, simulators) show the exact command first.
struct DeveloperPage: View {
    let model: DeveloperModel
    @SwiftUI.Environment(AppModel.self) private var app
    @State private var showFilesConfirm = false
    @State private var showProjectsConfirm = false
    @State private var pending: DeveloperAction?

    var body: some View {
        Form {
            headerSection
            if case .scanning(let progress) = model.files.state {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Scanning")
                        Text("\(progress.files.formatted()) files checked")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            DeveloperFileSection(
                title: "Xcode", ruleIDs: DeveloperRuleIDs.xcode, commandIDs: [],
                footer: "Build products and caches that Xcode creates again when it needs them.",
                model: model, access: app.access, pending: $pending)
            DeveloperSimulatorSection(model: model, pending: $pending)
            DeveloperFileSection(
                title: "Package managers", ruleIDs: DeveloperRuleIDs.packageManagers,
                commandIDs: DeveloperRuleIDs.packageCommands,
                footer: "Download caches. The tools fetch them again when a project needs them.",
                model: model, access: app.access, pending: $pending)
            dockerSection
            DeveloperProjectsSection(
                model: model, settings: app.settings, access: app.access, showConfirm: $showProjectsConfirm)
        }
        .formStyle(.grouped)
        .disabled(model.files.isCleaning || model.projects.isCleaning)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .cleanFlow(model: model.files, summary: model.filesConfirmation(), isPresented: $showFilesConfirm) {
            model.files.clean(mode: $0, permanentConfirmed: $1)
        }
        .cleanFlow(
            model: model.projects, summary: model.projectSelection().confirmation,
            isPresented: $showProjectsConfirm
        ) {
            model.cleanProjects(mode: $0, permanentConfirmed: $1)
        }
        .confirmationDialog(
            pending.map(Self.dialogTitle) ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(Self.buttonTitle(action), role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(message(for: action))
        }
        .task { await model.loadIfNeeded() }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            PageHeader(
                symbol: Page.developer.symbol,
                color: Page.developer.color,
                title: Page.developer.title,
                subtitle: headerSubtitle
            )
            if let notice = model.files.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
            }
        }
    }

    private var headerSubtitle: String {
        switch model.files.state {
        case .idle: "Scan to see what Xcode and your tools are keeping. Safe items are selected for you."
        case .scanning: "Scanning…"
        case .results, .cleaning, .finished:
            model.files.scanWasPartial
                ? "The scan stopped early. These are the items found so far."
                : "Safe items are selected. Review items are not."
        }
    }

    // MARK: Docker

    private var dockerSection: some View {
        Section {
            if let command = model.command(DeveloperRuleIDs.dockerCommand) {
                DeveloperCommandRow(command: command, model: model, pending: $pending)
            }
            if let row = model.rows([DeveloperRuleIDs.dockerInfo]).first {
                SmartCleanRuleRow(row: row, model: model.files, access: app.access)
            } else {
                Text(dockerImageNote)
                    .foregroundStyle(.secondary)
            }
            if model.dockerDesktopInstalled == true {
                Button("Open Docker Desktop") { DeveloperActions.openDockerDesktop() }
                    .accessibilityHint("Opens Docker Desktop so you can shrink its disk image in Settings")
            } else if model.dockerDesktopInstalled == false {
                Text("Docker Desktop is not installed.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Docker")
        } footer: {
            Text("Volumes are never touched.")
        }
    }

    private var dockerImageNote: String {
        switch model.files.state {
        case .idle: "Scan to measure Docker's disk image."
        case .scanning: "Scanning…"
        default: "No Docker disk image found."
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        if case .cleaning(let progress) = model.files.state {
            CleanProgressBar(done: progress?.done ?? 0, total: progress?.total ?? 0)
        } else if case .cleaning(let progress) = model.projects.state {
            CleanProgressBar(done: progress?.done ?? 0, total: progress?.total ?? 0)
        } else if case .results = model.files.state,
                  model.files.sections.contains(where: { !$0.selectableRows.isEmpty }) {
            CleanBar(
                summary: CleanBarText.summary(
                    bytes: model.files.selectedBytes, itemCount: model.files.selectedItemCount,
                    mode: model.files.deleteMode),
                detail: CleanBarText.detail(
                    itemCount: model.files.selectedItemCount, privateBytes: model.files.selectedPrivateBytes),
                canClean: model.files.selectedItemCount > 0 && !model.isBusy
            ) {
                showFilesConfirm = true
            }
        }
    }

    // MARK: Confirmation of commands and deletions

    private static func dialogTitle(_ action: DeveloperAction) -> String {
        switch action {
        case .command(_, let title): "\(title)?"
        case .device(let device): "Delete “\(device.name)”?"
        case .runtime(let runtime): "Delete the \(runtime.name) runtime?"
        }
    }

    private static func buttonTitle(_ action: DeveloperAction) -> String {
        switch action {
        case .command: "Run"
        case .device, .runtime: "Delete"
        }
    }

    private func message(for action: DeveloperAction) -> String {
        switch action {
        case .command(let command, _):
            return "TruongCleaner will run:\n\(model.commandText(command))\n\n"
                + "The tool removes the items itself, so they cannot be put back from the Trash."
        case .device(let device):
            return "Deletes this simulator with its apps and data"
                + sizePhrase(device.size)
                + ". TruongCleaner will run:\n/usr/bin/xcrun simctl delete \(device.udid)\n\n"
                + "It cannot be put back."
        case .runtime(let runtime):
            return "Deletes the simulator runtime \(runtime.name)"
                + (runtime.bytes.map { ", about \(ByteFormatter.string($0))" } ?? "")
                + ". TruongCleaner will run:\n/usr/bin/xcrun simctl runtime delete \(runtime.identifier)\n\n"
                + "Xcode can download it again."
        }
    }

    private func sizePhrase(_ size: MeasuredSize) -> String {
        if case .bytes(let bytes) = size { ", about \(ByteFormatter.string(bytes))" } else { "" }
    }

    private func perform(_ action: DeveloperAction) {
        switch action {
        case .command(let command, _):
            Task { await model.run(command) }
        case .device(let device):
            Task { await model.deleteDevice(device) }
        case .runtime(let runtime):
            Task { await model.deleteRuntime(runtime) }
        }
    }
}

/// A section of file rules, with the owner commands of the same tools below them.
struct DeveloperFileSection: View {
    let title: String
    let ruleIDs: [String]
    /// Owner-command rules shown after the file rows.
    let commandIDs: [String]
    let footer: String
    let model: DeveloperModel
    let access: AccessState
    @Binding var pending: DeveloperAction?

    var body: some View {
        let rows = model.rows(ruleIDs)
        let section = SmartCleanSection(category: .developer, rows: rows)
        Section {
            if rows.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                SmartCleanRuleRow(row: row, model: model.files, access: access)
            }
            ForEach(commandIDs.compactMap(model.command)) { command in
                DeveloperCommandRow(command: command, model: model, pending: $pending)
            }
        } header: {
            HStack {
                if section.selectableRows.isEmpty {
                    Text(title)
                } else {
                    Toggle(
                        title,
                        isOn: Binding(
                            get: { model.files.isSelected(section) },
                            set: { model.files.setSelected($0, for: section) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Select all in \(title)")
                }
                Spacer()
                SizeText(bytes: section.bytes)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(footer)
        }
    }

    private var emptyText: String {
        switch model.files.state {
        case .idle: "Scan to see what can be cleaned here."
        case .scanning: "Scanning…"
        case .results, .cleaning, .finished: "Nothing to clean here."
        }
    }
}

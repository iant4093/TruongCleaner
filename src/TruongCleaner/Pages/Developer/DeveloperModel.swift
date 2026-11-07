import CleanerActions
import CleanerCore
import CleanerScanner
import Foundation
import Observation
import os

/// Holds everything on the Developer page (`docs/UI.md` §4.4): file rules scanned and cleaned through two
/// `SmartCleanModel`s (so every deletion still goes through `SafetyGate`), owner commands run through
/// `OwnerCommandRunner`, and the simulator tables.
///
/// Scanning, sizing and every command run off the main actor. This class holds display data and choices.
@Observable @MainActor
final class DeveloperModel {
    /// Where the simulator lists stand.
    enum SimulatorStatus: Equatable {
        case notLoaded
        case loading
        case ready
        /// The lists cannot be read. Holds the reason in plain words.
        case unavailable(String)
    }

    private static let log = Logger(subsystem: "com.iant4093.TruongCleaner", category: "developer")

    /// Xcode, package manager and Docker file rules, scanned by the toolbar's Scan button.
    let files: SmartCleanModel
    /// `dev.projectArtifacts` inside the project folders, scanned by "Find Build Folders".
    let projects: SmartCleanModel

    private(set) var simulatorStatus: SimulatorStatus = .notLoaded
    private(set) var devices: [SimulatorDeviceRow] = []
    private(set) var runtimes: [SimulatorRuntimeRow] = []
    private(set) var runtimeNote: String?

    /// Candidate executable paths that exist on this Mac, or `nil` until the first check.
    private(set) var existingTools: Set<String>?

    /// Whether Docker Desktop is installed, or `nil` until the page has looked.
    private(set) var dockerDesktopInstalled: Bool?

    /// The last run of each command, by rule ID. In memory only: `HistoryStore` has no entry type for
    /// owner commands yet, so these are not written to `history.jsonl`.
    private(set) var runs: [String: DeveloperCommandRun] = [:]

    /// The last simulator or runtime deleted from a table.
    private(set) var lastItemRun: DeveloperCommandRun?

    /// Keys of the commands running now (a rule ID, `device:<UDID>` or `runtime:<identifier>`).
    private(set) var running: Set<String> = []

    /// Findings of the project build folders the user ticked.
    private(set) var selectedProjectFindings: Set<UUID> = []

    private let settings: SettingsStore
    private let runner = OwnerCommandRunner()
    private let commandsByRule: [String: DeveloperCommand]

    /// Creates the model.
    ///
    /// - Parameters:
    ///   - settings: Enabled rules, exclusions, the delete mode and the project folders.
    ///   - services: Shared app objects, passed on to the two file models.
    init(settings: SettingsStore, services: Services) {
        self.settings = settings
        self.files = SmartCleanModel(
            settings: settings, services: services,
            scope: SmartCleanScope(ruleIDs: DeveloperRuleIDs.scanned))
        self.projects = SmartCleanModel(
            settings: settings, services: services,
            scope: SmartCleanScope(ruleIDs: [DeveloperRuleIDs.projects], usesProjectFolders: true))
        self.commandsByRule = Dictionary(
            uniqueKeysWithValues: settings.catalog.compactMap { rule in
                DeveloperCommand(rule: rule).map { (rule.id, $0) }
            })
    }

    // MARK: Toolbar scan

    /// The toolbar's Scan button can start: nothing scans or cleans.
    var canScan: Bool { files.canScan && !isBusy }

    /// True while any command, scan or clean runs, so a second one cannot start beside it.
    var isBusy: Bool {
        !running.isEmpty || files.isCleaning || projects.isCleaning || files.isScanning || projects.isScanning
    }

    /// Scans the file rules and reads the simulators and tools again.
    func scan() {
        guard canScan else { return }
        files.scan()
        Task {
            await refreshSimulators()
            await refreshTools()
        }
    }

    /// Reads what the page needs when it appears for the first time.
    func loadIfNeeded() async {
        if dockerDesktopInstalled == nil { dockerDesktopInstalled = DeveloperActions.dockerDesktopURL() != nil }
        if simulatorStatus == .notLoaded { await refreshSimulators() }
        if existingTools == nil { await refreshTools() }
    }

    // MARK: Rows by section

    /// The scanned rows for these rule IDs, in the order given. A rule with nothing found has no row.
    func rows(_ ids: [String]) -> [SmartCleanRow] {
        let byID = Dictionary(uniqueKeysWithValues: files.sections.flatMap(\.rows).map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// The command for a rule, unless the user turned the rule off in Settings or it cannot run.
    func command(_ ruleID: String) -> DeveloperCommand? {
        guard let command = commandsByRule[ruleID], settings.isEnabled(command.rule) else { return nil }
        return command
    }

    /// Selected rows and bytes of the file models, grouped for the confirmation.
    func filesConfirmation() -> CleanConfirmation {
        let groups: [(title: String, ids: [String])] = [
            ("Xcode", DeveloperRuleIDs.xcode),
            ("Package managers", DeveloperRuleIDs.packageManagers),
        ]
        let lines = groups.compactMap { group -> String? in
            let bytes = rows(group.ids)
                .filter { files.isSelected($0) }
                .reduce(Int64(0)) { $0 + $1.bytes }
            return bytes > 0 ? "\(group.title): \(ByteFormatter.string(bytes))" : nil
        }
        return CleanConfirmation(bytes: files.selectedBytes, lines: lines)
    }

    // MARK: Owner commands

    /// Whether the tool for a command is on this Mac. `nil` until the first check.
    func isInstalled(_ command: DeveloperCommand) -> Bool? {
        existingTools.map { command.isInstalled(in: $0) }
    }

    /// The exact commands a run would launch, one per line.
    func commandText(_ command: DeveloperCommand) -> String {
        command.commandText(in: existingTools ?? [])
    }

    /// Runs a command through `OwnerCommandRunner` and keeps what it did. Does nothing when its tool is
    /// missing, when the tool has not been looked for yet, or when something else is running.
    func run(_ command: DeveloperCommand) async {
        guard !isBusy, let existing = existingTools, command.isInstalled(in: existing) else { return }
        running.insert(command.id)
        defer { running.remove(command.id) }

        var steps: [DeveloperCommandRun.Step] = []
        for step in command.steps {
            let result = await runner.run(step.id)
            steps.append(DeveloperCommandRun.Step(text: step.text(in: existing), result: result))
            // Docker's second step only follows a first one that worked.
            if !result.succeeded { break }
        }
        let run = DeveloperCommandRun(steps: steps, finishedAt: Date())
        runs[command.id] = run
        Self.log.info(
            "Owner command \(command.id, privacy: .public): \(run.summary, privacy: .public)")
        if command.id == DeveloperRuleIDs.simulatorCommand { await refreshSimulators() }
    }

    // MARK: Simulators

    /// Why simulators cannot be deleted right now, or `nil` when they can.
    var simulatorBlockReason: String? {
        switch simulatorStatus {
        case .notLoaded, .loading: "Reading the simulator list…"
        case .unavailable(let message): message
        case .ready: devices.contains { !$0.isShutDown } ? "A simulator is running. Quit Simulator first." : nil
        }
    }

    /// Why this device cannot be deleted, or `nil` when it can.
    func deleteBlockReason(_ device: SimulatorDeviceRow) -> String? {
        if isBusy { return "Something else is running." }
        return device.isShutDown ? nil : "This simulator is running. Shut it down first."
    }

    /// Why this runtime cannot be deleted, or `nil` when it can. A running simulator may use it.
    func deleteBlockReason(_ runtime: SimulatorRuntimeRow) -> String? {
        if isBusy { return "Something else is running." }
        if !runtime.isDeletable { return "Xcode says this runtime cannot be deleted." }
        return simulatorBlockReason
    }

    /// Reads the device and runtime lists, then measures each device's data folder.
    func refreshSimulators() async {
        guard simulatorStatus != .loading else { return }
        simulatorStatus = .loading
        switch await SimulatorLoader.list() {
        case .failure(let failure):
            devices = []
            runtimes = []
            runtimeNote = nil
            simulatorStatus = .unavailable(failure.message)
        case .success(let snapshot):
            devices = snapshot.devices
            runtimes = snapshot.runtimes
            runtimeNote = snapshot.runtimeNote
            simulatorStatus = .ready
            let sizes = await SimulatorLoader.measure(
                udids: snapshot.devices.map(\.udid), home: FileManager.default.homeDirectoryForCurrentUser)
            // A measurement cut short leaves sizes unread. Start over on the next visit.
            guard !Task.isCancelled else {
                simulatorStatus = .notLoaded
                return
            }
            devices = devices.map { device in
                var device = device
                device.size = sizes[device.udid] ?? .unknown
                return device
            }
        }
    }

    /// Deletes one simulator with `simctl delete <UDID>`.
    func deleteDevice(_ device: SimulatorDeviceRow) async {
        guard !isBusy, device.isShutDown else { return }
        let key = "device:\(device.udid)"
        running.insert(key)
        defer { running.remove(key) }
        let result = await runner.deleteSimulator(udid: device.udid)
        lastItemRun = DeveloperCommandRun(
            steps: [.init(text: "/usr/bin/xcrun simctl delete \(device.udid)", result: result)],
            finishedAt: Date())
        Self.log.info("Simulator delete: \(self.lastItemRun?.summary ?? "", privacy: .public)")
        await refreshSimulators()
    }

    /// Deletes one simulator runtime with `simctl runtime delete <identifier>`.
    func deleteRuntime(_ runtime: SimulatorRuntimeRow) async {
        guard !isBusy, runtime.isDeletable else { return }
        let key = "runtime:\(runtime.identifier)"
        running.insert(key)
        defer { running.remove(key) }
        let result = await runner.deleteSimulatorRuntime(identifier: runtime.identifier)
        lastItemRun = DeveloperCommandRun(
            steps: [.init(text: "/usr/bin/xcrun simctl runtime delete \(runtime.identifier)", result: result)],
            finishedAt: Date())
        Self.log.info("Runtime delete: \(self.lastItemRun?.summary ?? "", privacy: .public)")
        await refreshSimulators()
    }

    // MARK: Tools

    /// Looks for the executables the commands may launch.
    func refreshTools() async {
        let paths = Array(Set(commandsByRule.values.flatMap(\.candidatePaths)))
        existingTools = await Self.findExecutables(paths)
    }

    /// Which of these absolute paths are executable files. A read-only check; it launches nothing.
    @concurrent
    private static func findExecutables(_ paths: [String]) async -> Set<String> {
        Set(paths.filter { FileManager.default.isExecutableFile(atPath: $0) })
    }

    // MARK: Project folders

    /// A project and the build folders found in it.
    struct ProjectGroup: Identifiable {
        /// The project's folder name, or "Other" for a result outside every chosen folder.
        let name: String
        /// The chosen folder that holds the project. `nil` for "Other".
        let location: URL?
        /// Build folders, largest first.
        let findings: [Finding]

        var id: String { location.map { $0.path + "/" + name } ?? name }

        var bytes: Int64 { findings.reduce(0) { $0 + $1.allocatedBytes } }
    }

    /// Chosen folders the scan will use. The rest are too broad or protected (`~`, `~/Library`, …).
    func usableProjectFolders() -> [URL] {
        guard let rule = settings.catalog.first(where: { $0.id == DeveloperRuleIDs.projects }),
              let spec = rule.roots.first else { return [] }
        let environment = CleanerCore.Environment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            projectFolders: settings.projectFolders)
        let usable = Set(RootExpansion.starts(of: spec, in: environment).map { $0.path })
        return settings.projectFolders.filter { usable.contains($0.path) }
    }

    /// Whether the scan will search this folder.
    func isUsable(_ folder: URL) -> Bool {
        usableProjectFolders().contains { $0.path == folder.path }
    }

    /// True when "Find Build Folders" can start.
    var canFindBuildFolders: Bool {
        projects.canScan && !isBusy && !usableProjectFolders().isEmpty
    }

    /// Searches the project folders for build output (`dev.projectArtifacts`).
    func findBuildFolders() {
        guard canFindBuildFolders else { return }
        selectedProjectFindings = []
        projects.scan()
    }

    /// Findings of the project rule on screen, grouped by project, largest group first.
    var projectGroups: [ProjectGroup] {
        let findings = projects.sections.flatMap(\.rows)
            .first(where: { $0.rule.id == DeveloperRuleIDs.projects })?.result.findings ?? []
        let folders = settings.projectFolders.map { ($0, $0.pathComponents) }
        var grouped: [String: (name: String, location: URL?, findings: [Finding])] = [:]
        for finding in findings {
            let parts = finding.url.pathComponents
            // The longest chosen folder that holds the finding; the project is the next folder down.
            let owner = folders
                .filter { parts.count > $0.1.count + 1 && parts.starts(with: $0.1) }
                .max { $0.1.count < $1.1.count }
            let name = owner.map { parts[$0.1.count] } ?? "Other"
            let key = (owner?.0.path ?? "") + "/" + name
            grouped[key, default: (name, owner?.0, [])].findings.append(finding)
        }
        return grouped.values
            .map { ProjectGroup(
                name: $0.name, location: $0.location,
                findings: $0.findings.sorted { $0.allocatedBytes > $1.allocatedBytes }) }
            .sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
    }

    /// Whether every build folder of the project is ticked.
    func isSelected(_ group: ProjectGroup) -> Bool {
        !group.findings.isEmpty && group.findings.allSatisfy { selectedProjectFindings.contains($0.id) }
    }

    /// Ticks or clears every build folder of a project.
    func setSelected(_ isOn: Bool, for group: ProjectGroup) {
        for finding in group.findings {
            if isOn { selectedProjectFindings.insert(finding.id) } else { selectedProjectFindings.remove(finding.id) }
        }
    }

    /// Findings that are ticked and still on screen.
    private func selectedFindings(in groups: [ProjectGroup]) -> [Finding] {
        groups.flatMap(\.findings).filter { selectedProjectFindings.contains($0.id) }
    }

    /// Number and size of the ticked build folders, and the lines for the confirmation.
    func projectSelection() -> (count: Int, confirmation: CleanConfirmation) {
        let groups = projectGroups
        let selected = selectedFindings(in: groups)
        let lines = groups.compactMap { group -> String? in
            let bytes = group.findings.filter { selectedProjectFindings.contains($0.id) }
                .reduce(Int64(0)) { $0 + $1.allocatedBytes }
            return bytes > 0 ? "\(group.name): \(ByteFormatter.string(bytes))" : nil
        }
        return (selected.count, CleanConfirmation(bytes: selected.reduce(0) { $0 + $1.allocatedBytes }, lines: lines))
    }

    /// Cleans the ticked build folders. Only findings still on screen are cleaned.
    func cleanProjects(mode: DeleteMode, permanentConfirmed: Bool) {
        let ids = Set(selectedFindings(in: projectGroups).map(\.id))
        guard !ids.isEmpty, !isBusy else { return }
        projects.clean(findingIDs: ids, mode: mode, permanentConfirmed: permanentConfirmed)
    }
}

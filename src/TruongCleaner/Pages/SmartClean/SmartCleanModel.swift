import CleanerActions
import CleanerCore
import CleanerScanner
import Foundation
import Observation
import os

/// The rules of one selected row, ready to hand to the cleaner. Plain values, safe to send.
nonisolated struct CleanInput: Sendable {
    let rule: Rule
    let findings: [Finding]
}

/// Which rules a ``SmartCleanModel`` offers, and whether it searches the user's project folders.
///
/// The default is the Smart Clean page: every offered, enabled rule, no project folders. The Developer
/// page makes models for its own rules.
struct SmartCleanScope: Sendable {
    /// Rule IDs to offer. `nil` offers every rule that Smart Clean offers.
    var ruleIDs: Set<String>?
    /// Whether the scan and the gate get the folders from Developer > Project Folders
    /// (`Environment.projectFolders`). Rules with `RootSpec.Base.userChosen` find nothing without them.
    var usesProjectFolders = false

    /// The Smart Clean page's scope.
    static let smartClean = SmartCleanScope()
}

/// Runs a Smart Clean scan, holds what it found, and drives the clean (`docs/UI.md` §4.2).
///
/// Scanning, cleaning, Put Back and Free Space Now all run off the main actor. This class holds
/// display data and the user's choices. Every deletion goes through `CleanerActions.Cleaner`.
@Observable @MainActor
final class SmartCleanModel {
    enum State {
        /// Nothing scanned yet, or the last results were dismissed.
        case idle
        /// A scan is running.
        case scanning(ScanProgress)
        /// A scan finished (or was stopped) and the user is reviewing.
        case results
        /// A clean is running. `nil` until the first item.
        case cleaning(CleanProgress?)
        /// A clean finished.
        case finished(CleanReport)
    }

    private static let log = Logger(subsystem: "com.iant4093.TruongCleaner", category: "smartclean")

    /// Text shown when the exclusions file cannot be read. Unknown means keep: nothing is scanned.
    static let exclusionsUnreadableMessage = "Exclusions could not be read — check Settings > Exclusions"

    private(set) var state: State = .idle

    /// A short explanation of why a scan or clean did not start, or `nil`.
    private(set) var notice: String?

    /// IDs of the rules whose items will be cleaned. Safe rules start selected, Review rules do not.
    private(set) var selectedRuleIDs: Set<String> = []

    /// True when the scan was stopped or a root could not be fully read. Sizes may be too low.
    private(set) var scanWasPartial = false

    /// How long the last scan took.
    private(set) var scanDuration: Duration?

    /// True when Full Disk Access was granted after this scan began (REQ-PERM-03). The page offers a
    /// new scan; it never starts one by itself.
    private(set) var accessChangedSinceScan = false

    /// What Put Back and Free Space Now did for the clean on screen, in plain words.
    private(set) var followUpNotes: [String] = []

    /// True while Put Back or Free Space Now is running.
    private(set) var isWorking = false

    /// Findings put back from the Trash since the clean on screen finished.
    private(set) var restoredFindingIDs: Set<UUID> = []

    @ObservationIgnored private(set) var scanRules: [Rule] = []
    @ObservationIgnored private var results: [String: SmartCleanRow] = [:]
    @ObservationIgnored private var finishedRuleIDs: Set<String> = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var cleanTask: Task<Void, Never>?

    private let settings: SettingsStore
    private let scope: SmartCleanScope
    private let engine = ScanEngine()
    private let history: HistoryStore
    private let undo: UndoService

    // Observation does not track the plain dictionaries above, so changes bump this counter.
    private var revision = 0

    /// Creates the model.
    ///
    /// - Parameters:
    ///   - settings: Enabled rules, exclusions and the delete mode.
    ///   - services: Shared app objects; its `history` is the only writer of `history.jsonl`.
    ///   - scope: Which rules the model offers. The default is the Smart Clean page.
    init(settings: SettingsStore, services: Services, scope: SmartCleanScope = .smartClean) {
        self.settings = settings
        self.scope = scope
        // One shared HistoryStore (an actor) is the only writer of history.jsonl.
        self.history = services.history
        self.undo = UndoService(trash: Services.trashLocations(home: FileManager.default.homeDirectoryForCurrentUser))
    }

    // MARK: State

    var isScanning: Bool {
        if case .scanning = state { true } else { false }
    }

    var isCleaning: Bool {
        if case .cleaning = state { true } else { false }
    }

    /// A scan can start when nothing is running.
    var canScan: Bool {
        switch state {
        case .idle, .results, .finished: true
        case .scanning, .cleaning: false
        }
    }

    /// The report of the clean on screen, or `nil`.
    var finishedReport: CleanReport? {
        if case .finished(let report) = state { report } else { nil }
    }

    /// How items leave their place, from Settings > General.
    var deleteMode: DeleteMode {
        settings.deleteMode == .permanent ? .permanent : .trash
    }

    /// Names of the categories a scan covers, for the page before the first scan.
    var categoriesChecked: [CleanerCore.Category] {
        let categories = Set(offeredRules().map(\.category))
        return CleanerCore.Category.allCases.filter(categories.contains)
    }

    // MARK: Results

    /// Visible rows grouped by category, in catalog order. Empty rows are left out.
    var sections: [SmartCleanSection] {
        _ = revision
        let rows = scanRules.compactMap { results[$0.id] }.filter(\.isVisible)
        return CleanerCore.Category.allCases.compactMap { category in
            let inCategory = rows.filter { $0.rule.category == category }
            return inCategory.isEmpty ? nil : SmartCleanSection(category: category, rows: inCategory)
        }
    }

    /// Progress per category while a scan runs.
    var categoryProgress: [CategoryProgress] {
        _ = revision
        return CleanerCore.Category.allCases.compactMap { category in
            let rules = scanRules.filter { $0.category == category }
            guard !rules.isEmpty else { return nil }
            let done = rules.filter { finishedRuleIDs.contains($0.id) }
            let bytes = done.reduce(Int64(0)) { $0 + (results[$1.id]?.bytes ?? 0) }
            return CategoryProgress(
                category: category, totalRules: rules.count, finishedRules: done.count, bytes: bytes)
        }
    }

    /// Rows that will be cleaned.
    var selectedRows: [SmartCleanRow] {
        sections.flatMap(\.rows).filter { $0.isSelectable && selectedRuleIDs.contains($0.id) }
    }

    /// Allocated bytes of everything selected. Shown as "about".
    var selectedBytes: Int64 { selectedRows.reduce(0) { $0 + $1.bytes } }

    /// Bytes the selected items own alone, without space shared with APFS clones. Shown as "at least".
    var selectedPrivateBytes: Int64 { selectedRows.reduce(0) { $0 + $1.privateBytes } }

    /// Number of items that will be cleaned.
    var selectedItemCount: Int { selectedRows.reduce(0) { $0 + $1.result.findings.count } }

    /// Bytes selected per category, for the confirmation.
    var selectedBytesByCategory: [(category: CleanerCore.Category, bytes: Int64)] {
        sections.compactMap { section in
            let bytes = section.rows
                .filter { $0.isSelectable && selectedRuleIDs.contains($0.id) }
                .reduce(Int64(0)) { $0 + $1.bytes }
            return bytes > 0 ? (section.category, bytes) : nil
        }
    }

    // MARK: Selection

    func isSelected(_ row: SmartCleanRow) -> Bool {
        row.isSelectable && selectedRuleIDs.contains(row.id)
    }

    /// Selects or clears one rule. Info rules and rules with nothing found are ignored.
    func setSelected(_ isOn: Bool, for row: SmartCleanRow) {
        guard row.isSelectable else { return }
        if isOn { selectedRuleIDs.insert(row.id) } else { selectedRuleIDs.remove(row.id) }
    }

    /// Whether every selectable rule of the section is selected. False when it has none.
    func isSelected(_ section: SmartCleanSection) -> Bool {
        let rows = section.selectableRows
        return !rows.isEmpty && rows.allSatisfy { selectedRuleIDs.contains($0.id) }
    }

    /// Selects or clears every selectable rule of a category.
    func setSelected(_ isOn: Bool, for section: SmartCleanSection) {
        for row in section.selectableRows {
            if isOn { selectedRuleIDs.insert(row.id) } else { selectedRuleIDs.remove(row.id) }
        }
    }

    // MARK: Scan

    /// Starts a scan of every enabled rule. Does nothing while a scan or clean is running.
    func scan() {
        guard canScan else { return }
        notice = nil
        resetResults()
        state = .scanning(ScanProgress())
        scanTask = Task { await runScan() }
    }

    /// Marks the results on screen, or the scan in progress, as measured before Full Disk Access was granted.
    func noteAccessGranted() {
        switch state {
        case .scanning, .results: accessChangedSinceScan = true
        case .idle, .cleaning, .finished: break
        }
    }

    /// Stops a running scan within about 100 ms and keeps what was found so far.
    func stopScan() {
        scanTask?.cancel()
    }

    /// Rules the Smart Clean page offers: enabled rules, minus owner commands and rules that delete
    /// from the Trash itself (`trash.user`), which have their own page.
    private func offeredRules() -> [Rule] {
        settings.enabledRules.filter(Self.isOffered).filter { scope.ruleIDs?.contains($0.id) ?? true }
    }

    /// Home folder, Darwin directories, the clock and, for a scope that uses them, the project folders.
    private func makeEnvironment() -> CleanerCore.Environment {
        var environment = ScanEnvironment.current()
        if scope.usesProjectFolders { environment.projectFolders = settings.projectFolders }
        return environment
    }

    private static func isOffered(_ rule: Rule) -> Bool {
        if case .ownerCommand = rule.match { return false }
        if rule.tier == .info {
            if case .measureOnly = rule.match { return true }
            return false
        }
        switch rule.action {
        case .trash:
            if case .measureOnly = rule.match { return false }
            return true
        case .deletePermanently, .ownerCommand, .none:
            return false
        }
    }

    private func runScan() async {
        defer { scanTask = nil }
        guard let exclusions = await settings.loadedExclusions() else {
            notice = Self.exclusionsUnreadableMessage
            state = .idle
            return
        }
        let rules = offeredRules()
        guard !rules.isEmpty else {
            notice = "Every rule is turned off. Turn some on in Settings > Rules."
            state = .idle
            return
        }
        let environment = makeEnvironment()
        scanRules = rules
        revision += 1

        let request = ScanRequest(rules: rules, environment: environment, userExclusions: exclusions)
        let rulesByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        var report: ScanReport?
        for await event in await engine.scan(request) {
            switch event {
            case .ruleStarted:
                break
            case .progress(let files, let bytes):
                if case .scanning = state { state = .scanning(ScanProgress(files: files, allocatedBytes: bytes)) }
            case .ruleFinished(let result):
                guard let rule = rulesByID[result.ruleID] else { continue }
                let row = SmartCleanRow(rule: rule, result: result)
                results[rule.id] = row
                finishedRuleIDs.insert(rule.id)
                if rule.tier == .safe, row.isSelectable { selectedRuleIDs.insert(rule.id) }
                revision += 1
            case .finished(let final):
                report = final
            }
        }
        scanDuration = report?.duration
        // Cancelled, or the stream ended early: what we have is incomplete.
        scanWasPartial = report?.partial ?? true
        revision += 1
        state = .results
    }

    private func resetResults() {
        results = [:]
        finishedRuleIDs = []
        selectedRuleIDs = []
        scanRules = []
        scanWasPartial = false
        scanDuration = nil
        accessChangedSinceScan = false
        followUpNotes = []
        restoredFindingIDs = []
        revision += 1
    }

    // MARK: Clean

    /// Cleans the selected rules.
    ///
    /// - Parameters:
    ///   - mode: Move to the Trash or delete for good.
    ///   - permanentConfirmed: Must be true for `.permanent`. The page sets it only after the second
    ///     confirmation; without it nothing happens.
    func clean(mode: DeleteMode, permanentConfirmed: Bool = false) {
        guard case .results = state else { return }
        if mode == .permanent, !permanentConfirmed { return }
        let inputs = selectedRows.map { CleanInput(rule: $0.rule, findings: $0.result.findings) }
        startClean(inputs, mode: mode, permanentConfirmed: permanentConfirmed)
    }

    /// Cleans only the listed findings of the rows on screen, whatever the rule selection says.
    ///
    /// The Developer page uses this to clean chosen projects out of one rule's results. Info rows and
    /// IDs that are not on screen are ignored.
    ///
    /// - Parameters:
    ///   - findingIDs: The findings to clean.
    ///   - mode: Move to the Trash or delete for good.
    ///   - permanentConfirmed: Must be true for `.permanent`, as in ``clean(mode:permanentConfirmed:)``.
    func clean(findingIDs: Set<UUID>, mode: DeleteMode, permanentConfirmed: Bool = false) {
        guard case .results = state else { return }
        if mode == .permanent, !permanentConfirmed { return }
        let inputs = sections.flatMap(\.rows).filter { $0.isSelectable }.compactMap { row -> CleanInput? in
            let findings = row.result.findings.filter { findingIDs.contains($0.id) }
            return findings.isEmpty ? nil : CleanInput(rule: row.rule, findings: findings)
        }
        startClean(inputs, mode: mode, permanentConfirmed: permanentConfirmed)
    }

    private func startClean(_ inputs: [CleanInput], mode: DeleteMode, permanentConfirmed: Bool) {
        guard !inputs.isEmpty else { return }
        notice = nil
        state = .cleaning(nil)
        cleanTask = Task { await runClean(inputs, mode: mode, permanentConfirmed: permanentConfirmed) }
    }

    private func runClean(_ inputs: [CleanInput], mode: DeleteMode, permanentConfirmed: Bool) async {
        defer { cleanTask = nil }
        guard let exclusions = await settings.loadedExclusions() else {
            notice = Self.exclusionsUnreadableMessage
            state = .results
            return
        }
        let environment = makeEnvironment()
        let history = self.history

        // At most ten updates a second reach the screen; the newest one wins.
        let (stream, continuation) = AsyncStream.makeStream(
            of: CleanProgress.self, bufferingPolicy: .bufferingNewest(1))
        let reader = Task {
            for await progress in stream {
                self.state = .cleaning(progress)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let report = await Self.execute(
            inputs, mode: mode, permanentConfirmed: permanentConfirmed, environment: environment,
            exclusions: exclusions, history: history
        ) { continuation.yield($0) }
        continuation.finish()
        reader.cancel()
        await reader.value
        Self.log.info("Clean finished: \(report.removedCount) of \(report.items.count) items removed")
        state = .finished(report)
    }

    /// Builds the plan and runs `Cleaner` off the main actor.
    @concurrent
    private static func execute(
        _ inputs: [CleanInput],
        mode: DeleteMode,
        permanentConfirmed: Bool,
        environment: CleanerCore.Environment,
        exclusions: [URL],
        history: HistoryStore,
        progress: @escaping @Sendable (CleanProgress) -> Void
    ) async -> CleanReport {
        let policy = PathPolicy(environment: environment, userExclusions: exclusions)
        var items: [PlannedItem] = []
        var ownersByRule: [String: [URL: [OwnerSpec]]] = [:]
        for input in inputs {
            let roots = ScanRoots.roots(for: input.rule, findings: input.findings, environment: environment)
            ownersByRule[input.rule.id] = ScanRoots.owners(for: input.rule, roots: roots)
            items.append(contentsOf: input.findings.map {
                PlannedItem(finding: $0, rule: input.rule, expandedRoots: roots)
            })
        }
        let owners = ownersByRule
        let plan = CleanPlan(items: items, mode: mode, permanentConfirmed: permanentConfirmed)
        let cleaner = Cleaner(
            gate: SafetyGate(),
            executor: FileManagerExecutor(),
            history: history,
            context: { item in
                let providers = LivenessProviders.make(roots: item.expandedRoots, rootSpecs: item.rule.roots)
                return GateContext(
                    environment: environment,
                    policy: policy,
                    expandedRoots: item.expandedRoots,
                    runningApps: providers.runningApps,
                    openFiles: providers.openFiles,
                    allowWholeBundle: item.rule.id == "installers.macOS",
                    rootOwners: owners[item.rule.id] ?? [:]
                )
            }
        )
        return await cleaner.run(plan, progress: progress)
    }

    // MARK: After a clean

    /// Leaves the result sheet. The scan results are out of date after a clean, so the page starts over.
    func dismissResult() {
        guard case .finished = state, !isWorking else { return }
        resetResults()
        state = .idle
    }

    /// Moves one item back from the Trash to where it was.
    ///
    /// Works only for the clean on screen and only while the item is still in the Trash with the
    /// same file ID; `UndoService` checks that.
    func putBack(_ item: ItemReport) async -> PutBackResult? {
        guard let report = finishedReport else { return nil }
        let result = await Self.performPutBack(item, cleanID: report.id, undo: undo, history: history)
        if case .restored = result { restoredFindingIDs.insert(item.findingID) }
        return result
    }

    /// Puts back every item the clean on screen moved to the Trash and notes the outcome.
    func putBackAll() async {
        guard let report = finishedReport, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        var restored = 0
        var refused: [String] = []
        for item in report.items where !restoredFindingIDs.contains(item.findingID) {
            guard case .moved = item.outcome else { continue }
            switch await putBack(item) {
            case .restored:
                restored += 1
            case .refused(let reason):
                refused.append("\(item.originalPath.lastPathComponent): \(reason.userMessage)")
            case .failed(let message):
                refused.append("\(item.originalPath.lastPathComponent): \(message)")
            case nil:
                break
            }
        }
        var notes = ["Put back \(itemsText(restored))."]
        notes.append(contentsOf: refused.prefix(5).map { "Not put back: \($0)" })
        if refused.count > 5 { notes.append("and \(refused.count - 5) more were not put back.") }
        followUpNotes.append(contentsOf: notes)
    }

    /// Deletes for good everything TruongCleaner moved to the Trash that is still there with the
    /// same file ID. Nothing else in the Trash is touched.
    func freeSpaceNow() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let report = await Self.performFreeSpace(undo: undo, history: history)
        var notes = [
            "Deleted \(itemsText(report.freed.count)) from the Trash, "
                + "about \(ByteFormatter.string(report.freedBytes)) freed."
        ]
        notes.append(contentsOf: report.skipped.prefix(5).map {
            "Left in the Trash: \($0.item.originalPath.lastPathComponent). \($0.reason)"
        })
        notes.append(contentsOf: report.failed.prefix(5).map {
            "Could not delete \($0.item.originalPath.lastPathComponent). \($0.reason)"
        })
        followUpNotes.append(contentsOf: notes)
    }

    @concurrent
    private static func performPutBack(
        _ item: ItemReport, cleanID: UUID, undo: UndoService, history: HistoryStore
    ) async -> PutBackResult {
        await undo.putBack(item, cleanID: cleanID, history: history)
    }

    @concurrent
    private static func performFreeSpace(undo: UndoService, history: HistoryStore) async -> FreeSpaceReport {
        await undo.freeSpaceNow(history: history, executor: FileManagerExecutor())
    }
}

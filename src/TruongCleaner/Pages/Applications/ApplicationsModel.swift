import CleanerActions
import CleanerCore
import CleanerScanner
import Darwin
import Foundation
import Observation
import os

/// One app in the Applications list.
struct ApplicationRow: Identifiable {
    /// What is known about the app.
    var facts: AppFacts
    /// Why the app cannot be uninstalled, or `nil` when it can.
    var refusal: UninstallRefusal?
    /// The measured size. `nil` until the app has been measured.
    var size: AppSize?

    var id: String { facts.id }

    /// Allocated bytes on disk, or `nil` while not measured (or when macOS refused the whole bundle).
    var bytes: Int64? { size?.allocatedBytes }
}

/// The Applications page (`docs/UNINSTALLER.md`): the list of installed apps, the leftovers of the
/// selected one, and the uninstall.
///
/// Reading, measuring and cleaning all run off the main actor. This class holds display data and the
/// user's choices. Every removal goes through `CleanerActions.Cleaner` and `SafetyGate`; the delete mode
/// is always the Trash, here and nowhere else.
@Observable @MainActor
final class ApplicationsModel {
    /// What the detail column shows.
    enum Detail {
        /// No app is selected.
        case none
        /// The leftovers of the selected app are being read.
        case loading
        /// The app can be uninstalled; the report lists what goes.
        case ready(UninstallReport)
        /// The app is refused, with the reason.
        case refused(AppFacts, UninstallRefusal)
    }

    /// The state of an uninstall.
    enum CleanState {
        case idle
        /// Running. `nil` until the first item.
        case cleaning(CleanProgress?)
        /// Done.
        case finished(CleanReport)
    }

    private static let log = Logger(subsystem: "com.iant4093.TruongCleaner", category: "applications")

    /// Text shown when the exclusions file cannot be read. Unknown means keep: nothing is removed.
    static let exclusionsUnreadableMessage = "Exclusions could not be read — check Settings > Exclusions"

    /// The apps found, sorted by name. Includes apps that cannot be uninstalled, with their reason.
    private(set) var rows: [ApplicationRow] = []

    /// True while the folders are read.
    private(set) var isLoading = false

    /// True while sizes are measured.
    private(set) var isMeasuring = false

    /// True after the first inventory has finished.
    private(set) var hasLoaded = false

    /// False when the list of apps could not be read in full. Matches by name are then left out.
    private(set) var inventoryIsComplete = true

    /// The ID (path) of the selected app.
    private(set) var selectedID: String?

    /// The selected app's report, or why there is none.
    private(set) var detail: Detail = .none

    /// IDs of the leftovers that will be moved. Safe ones start checked; Review ones do not.
    private(set) var checkedIDs: Set<UUID> = []

    /// The uninstall in progress or just finished.
    private(set) var cleanState: CleanState = .idle

    /// A short sentence about why something did not start, or `nil`.
    private(set) var notice: String?

    /// What Put Back did for the uninstall on screen, in plain words.
    private(set) var followUpNotes: [String] = []

    /// True while Put Back runs.
    private(set) var isWorking = false

    /// Findings put back from the Trash since the uninstall finished.
    private(set) var restoredFindingIDs: Set<UUID> = []

    @ObservationIgnored private var inventory: InstalledApps?
    @ObservationIgnored private var extraRow: ApplicationRow?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var cleanTask: Task<Void, Never>?

    private let settings: SettingsStore
    private let history: HistoryStore
    private let undo: UndoService
    private let sizer = AppSizer()

    /// Creates the model.
    ///
    /// - Parameters:
    ///   - settings: The exclusions that the safety gate must respect.
    ///   - services: Shared app objects; its `history` is the only writer of `history.jsonl`.
    init(settings: SettingsStore, services: Services) {
        self.settings = settings
        self.history = services.history
        self.undo = UndoService(trash: Services.trashLocations(home: FileManager.default.homeDirectoryForCurrentUser))
    }

    // MARK: State

    /// True while the uninstall runs.
    var isCleaning: Bool {
        if case .cleaning = cleanState { true } else { false }
    }

    /// The report of the uninstall on screen, or `nil`.
    var finishedReport: CleanReport? {
        if case .finished(let report) = cleanState { report } else { nil }
    }

    /// The app that is selected, from the list or dropped on the window.
    var selectedRow: ApplicationRow? {
        guard let selectedID else { return nil }
        return rows.first { $0.id == selectedID } ?? extraRow.flatMap { $0.id == selectedID ? $0 : nil }
    }

    /// The selected app's report, when it can be uninstalled.
    var report: UninstallReport? {
        if case .ready(let report) = detail { report } else { nil }
    }

    /// Leftovers the user left checked.
    var checkedLeftovers: [Leftover] {
        report?.leftovers.filter { checkedIDs.contains($0.id) } ?? []
    }

    /// Allocated bytes of the app and the checked leftovers. Shown as "about".
    var selectedBytes: Int64 {
        guard let report else { return 0 }
        return report.bundle.allocatedBytes + checkedLeftovers.reduce(0) { $0 + $1.finding.allocatedBytes }
    }

    /// Bytes only these items own (not shared with APFS clones). Shown as "at least".
    var selectedPrivateBytes: Int64 {
        guard let report else { return 0 }
        return report.bundle.privateBytes + checkedLeftovers.reduce(0) { $0 + $1.finding.privateBytes }
    }

    /// Number of items that will be moved: the app and the checked leftovers.
    var selectedItemCount: Int {
        report == nil ? 0 : 1 + checkedLeftovers.count
    }

    /// True when the app can be uninstalled now.
    var canClean: Bool {
        report != nil && !isCleaning && !isWorking && finishedReport == nil
    }

    /// Whether a launch agent was among the items that moved. It stays loaded until log out.
    var movedALaunchAgent: Bool {
        guard let finishedReport else { return false }
        return finishedReport.items.contains { item in
            guard case .moved = item.outcome else { return false }
            return item.originalPath.deletingLastPathComponent().lastPathComponent == "LaunchAgents"
        }
    }

    // MARK: Inventory

    /// Reads the application folders again and measures the apps. Does nothing while an uninstall runs.
    func reload() {
        guard !isCleaning else { return }
        loadTask?.cancel()
        notice = nil
        isLoading = true
        loadTask = Task { await runLoad() }
    }

    /// Stops reading and measuring.
    func stopLoading() {
        loadTask?.cancel()
    }

    /// Loads the list the first time the page shows.
    func loadIfNeeded() {
        if !hasLoaded, !isLoading { reload() }
    }

    private func runLoad() async {
        defer { loadTask = nil }
        let context = Self.makeContext()
        let found = await AppInventory.scan(folders: context.applicationFolders)
        guard !Task.isCancelled else {
            isLoading = false
            return
        }
        inventory = found
        inventoryIsComplete = found.isComplete
        let running = RunningBundleIDs.current()
        rows = found.apps.map { ApplicationRow(facts: $0, refusal: Self.refusal(for: $0, running: running, context: context)) }
        isLoading = false
        hasLoaded = true

        if selectedID != nil, selectedRow == nil {
            select(nil)
        } else if selectedID != nil {
            select(selectedID, force: true)
        }
        await measureSizes()
    }

    /// Measures every app a few at a time. Results reach the list at most ten times a second.
    private func measureSizes() async {
        isMeasuring = true
        defer { isMeasuring = false }
        let sizer = self.sizer
        let urls = rows.map(\.facts.url)
        var pending: [String: AppSize] = [:]
        var lastFlush = ContinuousClock.now

        func flush() {
            guard !pending.isEmpty else { return }
            let batch = pending
            pending = [:]
            for index in rows.indices {
                if let size = batch[rows[index].id] { rows[index].size = size }
            }
            lastFlush = ContinuousClock.now
        }

        await withTaskGroup(of: AppSize.self) { group in
            for url in urls { group.addTask { await sizer.size(of: url) } }
            for await size in group {
                pending[size.appID] = size
                if ContinuousClock.now - lastFlush >= .milliseconds(100) { flush() }
            }
        }
        if !Task.isCancelled { flush() }
    }

    /// Re-checks which apps are running, without reading any folder. Call when the app becomes active.
    func refreshRunningState() {
        guard hasLoaded, !isCleaning else { return }
        let context = Self.makeContext()
        let running = RunningBundleIDs.current()
        var changed = false
        for index in rows.indices {
            let refusal = Self.refusal(for: rows[index].facts, running: running, context: context)
            if refusal != rows[index].refusal {
                rows[index].refusal = refusal
                if rows[index].id == selectedID { changed = true }
            }
        }
        if changed { select(selectedID, force: true) }
    }

    private static func makeContext() -> UninstallContext {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return UninstallContext(
            home: home,
            applicationFolders: AppInventory.defaultFolders(home: home),
            ownBundleID: Bundle.main.bundleIdentifier,
            ownBundleURL: Bundle.main.bundleURL,
            currentUserID: UInt32(getuid()))
    }

    private static func isRunning(_ facts: AppFacts, in running: Set<String>?) -> Bool? {
        guard let running else { return nil }
        guard let identifier = facts.bundleID else { return false }
        return running.contains(identifier.lowercased())
    }

    private static func refusal(
        for facts: AppFacts, running: Set<String>?, context: UninstallContext
    ) -> UninstallRefusal? {
        UninstallEligibility.check(facts, isRunning: isRunning(facts, in: running), context: context)
    }

    // MARK: Selection

    /// Selects an app (or nothing) and reads its leftovers.
    ///
    /// - Parameters:
    ///   - id: The app's ID (`AppFacts.id`), or `nil` to clear the selection.
    ///   - force: Read again even if the app is already selected.
    func select(_ id: String?, force: Bool = false) {
        guard force || id != selectedID else { return }
        guard !isCleaning else { return }
        detailTask?.cancel()
        selectedID = id
        checkedIDs = []
        notice = nil
        guard id != nil, let row = selectedRow else {
            selectedID = nil
            detail = .none
            return
        }
        if let refusal = row.refusal {
            detail = .refused(row.facts, refusal)
            return
        }
        detail = .loading
        let facts = row.facts
        detailTask = Task { await loadDetail(facts) }
    }

    private func loadDetail(_ facts: AppFacts) async {
        defer { detailTask = nil }
        let context = Self.makeContext()
        let isRunning = Self.isRunning(facts, in: RunningBundleIDs.current())
        let result = await LeftoverFinder.find(
            for: facts, inventory: inventory ?? InstalledApps(apps: [], isComplete: false),
            isRunning: isRunning, context: context)
        guard !Task.isCancelled, selectedID == facts.id else { return }
        switch result {
        case .success(let found):
            detail = .ready(found)
            checkedIDs = Set(found.leftovers.filter { $0.tier == .safe }.map(\.id))
        case .failure(let refusal):
            detail = .refused(facts, refusal)
        }
    }

    /// Selects an app the user dropped on the window.
    ///
    /// An app in the list is selected there. Any other `.app` is shown with the reason it cannot be
    /// uninstalled (it is not in an Applications folder).
    func handleDrop(_ urls: [URL]) async {
        guard !isCleaning, let url = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else { return }
        if !hasLoaded {
            loadIfNeeded()
            await loadTask?.value
        }
        let id = AppFacts.id(for: url)
        if rows.contains(where: { $0.id == id }) {
            select(id)
            return
        }
        guard let facts = await AppInventory.facts(at: url) else {
            notice = "That is not an app."
            return
        }
        let context = Self.makeContext()
        extraRow = ApplicationRow(
            facts: facts,
            refusal: Self.refusal(for: facts, running: RunningBundleIDs.current(), context: context)
                ?? .outsideApplicationFolders)
        select(facts.id, force: true)
    }

    // MARK: Choices

    /// Whether a leftover is checked.
    func isChecked(_ leftover: Leftover) -> Bool {
        checkedIDs.contains(leftover.id)
    }

    /// Checks or unchecks one leftover.
    func setChecked(_ isOn: Bool, for leftover: Leftover) {
        if isOn { checkedIDs.insert(leftover.id) } else { checkedIDs.remove(leftover.id) }
    }

    // MARK: Uninstall

    /// Moves the app and the checked leftovers to the Trash.
    ///
    /// The delete mode is always the Trash. Permanent delete is not offered for uninstalling.
    func clean() {
        guard canClean, let report else { return }
        let rule = report.setup.rule
        let roots = report.setup.expandedRoots
        var items = [PlannedItem(finding: report.bundle, rule: rule, expandedRoots: roots)]
        items += checkedLeftovers.map { PlannedItem(finding: $0.finding, rule: rule, expandedRoots: roots) }
        let plan = CleanPlan(items: items, mode: .trash, permanentConfirmed: false)
        notice = nil
        followUpNotes = []
        restoredFindingIDs = []
        cleanState = .cleaning(nil)
        cleanTask = Task { await runClean(plan) }
    }

    private func runClean(_ plan: CleanPlan) async {
        defer { cleanTask = nil }
        guard let exclusions = await settings.loadedExclusions() else {
            notice = Self.exclusionsUnreadableMessage
            cleanState = .idle
            return
        }
        let environment = ScanEnvironment.current()
        let history = self.history

        // At most ten updates a second reach the screen; the newest one wins.
        let (stream, continuation) = AsyncStream.makeStream(
            of: CleanProgress.self, bufferingPolicy: .bufferingNewest(1))
        let reader = Task {
            for await progress in stream {
                self.cleanState = .cleaning(progress)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let result = await Self.execute(
            plan, environment: environment, exclusions: exclusions, history: history
        ) { continuation.yield($0) }
        continuation.finish()
        reader.cancel()
        await reader.value
        Self.log.info("Uninstall finished: \(result.removedCount) of \(result.items.count) items removed")
        cleanState = .finished(result)
    }

    /// Runs `Cleaner` off the main actor, with the app-aware owner check and the whole-bundle exception
    /// that only the uninstall rule has.
    @concurrent
    private static func execute(
        _ plan: CleanPlan,
        environment: CleanerCore.Environment,
        exclusions: [URL],
        history: HistoryStore,
        progress: @escaping @Sendable (CleanProgress) -> Void
    ) async -> CleanReport {
        let policy = PathPolicy(environment: environment, userExclusions: exclusions)
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
                    allowWholeBundle: item.rule.allowsWholeBundle,
                    rootOwners: [:]
                )
            }
        )
        return await cleaner.run(plan, progress: progress)
    }

    // MARK: After an uninstall

    /// Leaves the result sheet and reads the folders again, because the app is gone.
    func dismissResult() {
        guard case .finished = cleanState, !isWorking else { return }
        cleanState = .idle
        detailTask?.cancel()
        selectedID = nil
        extraRow = nil
        detail = .none
        checkedIDs = []
        reload()
    }

    /// Moves one item back from the Trash to where it was.
    func putBack(_ item: ItemReport) async -> PutBackResult? {
        guard let report = finishedReport else { return nil }
        let result = await Self.performPutBack(item, cleanID: report.id, undo: undo, history: history)
        if case .restored = result { restoredFindingIDs.insert(item.findingID) }
        return result
    }

    /// Puts back every item the uninstall moved to the Trash and notes the outcome.
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

    @concurrent
    private static func performPutBack(
        _ item: ItemReport, cleanID: UUID, undo: UndoService, history: HistoryStore
    ) async -> PutBackResult {
        await undo.putBack(item, cleanID: cleanID, history: history)
    }
}

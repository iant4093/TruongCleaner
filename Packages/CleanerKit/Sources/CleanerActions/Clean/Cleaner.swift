import CleanerCore
import CleanerScanner
import Foundation

/// Runs a clean: asks `SafetyGate` about each item, moves or deletes the allowed ones, and writes
/// everything to history (`.kiro/steering/safety.md`, rules 1, 11, 12 and 15).
///
/// Items are handled one after another, in plan order. If a parent was moved, a child inside it is
/// then reported as already gone.
public struct Cleaner: Sendable {
    /// Gives the open-files provider for a run. The default takes a fresh `OpenFilesSnapshot`.
    public typealias OpenFilesSource = @Sendable () async -> any OpenFilesProvider

    private let gate: SafetyGate
    private let executor: any ItemExecutor
    private let history: HistoryStore
    private let context: @Sendable (PlannedItem) -> GateContext
    private let openFilesSource: OpenFilesSource
    private let refreshItems: Int
    private let refreshTime: Duration

    /// Creates a cleaner.
    ///
    /// - Parameters:
    ///   - gate: The safety gate. Preview and run use the same one.
    ///   - executor: Moves or deletes an item. Use `FileManagerExecutor` in the app.
    ///   - history: Where the clean is recorded.
    ///   - context: The gate context for an item. Its `openFiles` is replaced by the run's snapshot.
    ///   - openFilesSource: Takes the open-files snapshot. The default scans all processes once.
    ///   - refreshItems: Take a new snapshot after this many items.
    ///   - refreshTime: Take a new snapshot after this long.
    public init(
        gate: SafetyGate,
        executor: any ItemExecutor,
        history: HistoryStore,
        context: @escaping @Sendable (PlannedItem) -> GateContext,
        openFilesSource: @escaping OpenFilesSource = { await OpenFilesSnapshot.take() },
        refreshItems: Int = 500,
        refreshTime: Duration = .seconds(30)
    ) {
        self.gate = gate
        self.executor = executor
        self.history = history
        self.context = context
        self.openFilesSource = openFilesSource
        self.refreshItems = max(1, refreshItems)
        self.refreshTime = refreshTime
    }

    // MARK: Preview

    /// What a clean would do with each item right now, by finding ID. Runs the same checks as `run`
    /// and never calls the executor or writes history.
    @concurrent
    public func preview(_ plan: CleanPlan) async -> [UUID: Verdict] {
        var snapshot = SnapshotKeeper(source: openFilesSource, items: refreshItems, time: refreshTime)
        var verdicts: [UUID: Verdict] = [:]
        for item in plan.items {
            let openFiles = await snapshot.current()
            verdicts[item.finding.id] = await decide(item, in: plan, openFiles: openFiles)
        }
        return verdicts
    }

    // MARK: Run

    /// Cleans the plan.
    ///
    /// `begin` goes to history before the first item. Each item's outcome is written before the next
    /// item is handled. If history cannot be written, the run stops: the rest are skipped and nothing
    /// is deleted without a record.
    ///
    /// - Parameter progress: Called before each item and once at the end.
    /// - Returns: One entry per planned item, with what happened to it.
    @concurrent
    public func run(_ plan: CleanPlan, progress: @Sendable (CleanProgress) -> Void) async -> CleanReport {
        let id = UUID()
        let startedAt = Date()
        let home = plan.items.first.map { context($0).environment.home }
        let before = home.flatMap(Self.availableSpace(on:))

        var historyWorks = true
        var began = false
        do {
            try await history.begin(plan, id: id, startedAt: startedAt)
            began = true
        } catch {
            historyWorks = false
        }

        var snapshot = SnapshotKeeper(source: openFilesSource, items: refreshItems, time: refreshTime)
        var reports: [ItemReport] = []
        reports.reserveCapacity(plan.items.count)
        for (index, item) in plan.items.enumerated() {
            progress(CleanProgress(done: index, total: plan.items.count, current: item.finding.url))
            let outcome: ItemOutcome
            if !historyWorks {
                outcome = .skipped(.probeFailed("history unavailable"))
            } else if Task.isCancelled {
                outcome = .skipped(.probeFailed("cancelled"))
            } else {
                let openFiles = await snapshot.current()
                outcome = await handle(item, in: plan, openFiles: openFiles)
            }
            let report = ItemReport(item.finding, outcome: outcome)
            reports.append(report)
            if historyWorks {
                do { try await history.record(report, cleanID: id) } catch { historyWorks = false }
            }
        }
        progress(CleanProgress(done: plan.items.count, total: plan.items.count, current: nil))

        let result = CleanReport(
            id: id,
            startedAt: startedAt,
            finishedAt: Date(),
            mode: plan.mode,
            items: reports,
            availableBefore: before,
            availableAfter: home.flatMap(Self.availableSpace(on:))
        )
        if began { try? await history.finish(result) }
        return result
    }

    // MARK: Per item

    /// The decision for one item. Preview and run both call this, so they cannot disagree.
    private func decide(_ item: PlannedItem, in plan: CleanPlan, openFiles: any OpenFilesProvider) async -> Verdict {
        if plan.mode == .permanent, !plan.permanentConfirmed {
            return .deny(.probeFailed("permanent delete not confirmed"))
        }
        switch Self.kind(of: item.rule.action) {
        case .trashable, .noAction:
            break
        case .notAFileAction:
            return .deny(.probeFailed("owner commands are not run by the file cleaner"))
        case .permanentOnly:
            // A rule that cannot go to the Trash needs an explicit, confirmed permanent clean.
            if plan.mode != .permanent { return .deny(.probeFailed("this rule needs permanent delete")) }
        }
        var gateContext = context(item)
        gateContext.openFiles = openFiles
        return await gate.authorize(item.finding, rule: item.rule, context: gateContext)
    }

    /// Asks the gate, then acts. Returns what happened.
    ///
    /// The executor gets the URL the gate verified (the item's real parent plus its name), never the
    /// path as scanned. Just before acting, the identity of that URL is read again.
    private func handle(_ item: PlannedItem, in plan: CleanPlan, openFiles: any OpenFilesProvider) async -> ItemOutcome {
        let url: URL
        switch await decide(item, in: plan, openFiles: openFiles) {
        case .deny(let reason): return .skipped(reason)
        case .allow(let verified): url = verified
        }
        if let reason = Self.recheck(url, against: item.finding) { return .skipped(reason) }
        do {
            switch plan.mode {
            case .trash:
                let destination = try await executor.moveToTrash(url)
                if Self.stillInPlace(url, fileID: item.finding.fileID) { return .failed("The item is still in place") }
                guard (try? GateSystem.lstatInfo(of: destination)) != nil else {
                    return .failed("It left its place but could not be found in the Trash")
                }
                return .moved(to: destination)
            case .permanent:
                let before = await Self.entryCount(of: url)
                do {
                    try await executor.deletePermanently(url)
                } catch {
                    return await Self.permanentFailure(error, url: url, countBefore: before)
                }
                if Self.stillInPlace(url, fileID: item.finding.fileID) { return .failed("The item is still in place") }
                return .deleted
            }
        } catch {
            // If the item is gone anyway, say so instead of claiming nothing happened.
            if plan.mode == .trash, Self.isGone(url) {
                return .failed("It left its place but its Trash location is unknown; look in the Trash")
            }
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Helpers

    private enum ActionKind {
        /// Moves to the Trash (or is deleted when the whole clean is permanent).
        case trashable
        /// Needs a confirmed permanent clean.
        case permanentOnly
        /// Runs a command, not a file action.
        case notAFileAction
        /// No action. The gate refuses it.
        case noAction
    }

    /// Classifies a rule's action. Anything that is not the plain Trash action counts as permanent-only
    /// unless it is an owner command or no action.
    private static func kind(of action: Action) -> ActionKind {
        if case .trash = action { return .trashable }
        if case .ownerCommand = action { return .notAFileAction }
        if case .none = action { return .noAction }
        return .permanentOnly
    }

    /// Reads the identity of the verified URL again, right before the executor acts, and compares both
    /// parts (`fsid` and `fileID`) with the scan (`safety.md` rule 6).
    ///
    /// - Returns: Why the item must be kept, or nil when it is still the entry the scan saw.
    static func recheck(_ url: URL, against finding: Finding) -> DenyReason? {
        do {
            let current = try GateSystem.identity(of: url)
            if current.fsid != finding.fsid || current.fileID != finding.fileID { return .changedSinceScan }
            return nil
        } catch let error as SysError {
            return error.isMissing ? .missing : .probeFailed(error.description)
        } catch {
            return .probeFailed("unexpected error")
        }
    }

    /// Longest the entry count may take.
    private static let countLimit: Duration = .seconds(5)

    /// Number of entries in a folder (nil for a file, a link, or when the walk was cut short or failed).
    private static func entryCount(of url: URL) async -> Int? {
        guard let info = try? GateSystem.lstatInfo(of: url), GateSystem.isDirectory(info) else { return nil }
        let options = WalkOptions(maxWorkers: 2, totalsDepth: 0, topFilesCount: 0, limit: countLimit)
        guard let result = try? await BulkWalker.walk(url, options: options),
            !result.partial, result.deniedCount == 0, result.otherErrors == 0
        else { return nil }
        return result.nodes.first?.fileCount
    }

    /// The outcome of a permanent delete that threw. When a folder is still there but has lost entries,
    /// the delete got partway, and the result says so (`safety.md` rule 12).
    private static func permanentFailure(_ error: any Error, url: URL, countBefore: Int?) async -> ItemOutcome {
        let message = error.localizedDescription
        guard !isGone(url), let info = try? GateSystem.lstatInfo(of: url), GateSystem.isDirectory(info) else {
            return .failed(message)
        }
        guard let before = countBefore, let after = await entryCount(of: url) else {
            return .failed("Partly deleted, or not at all; the folder is still there. \(message)")
        }
        if after < before {
            return .failed("Partly deleted: \(before - after) of \(before) items were removed before an error stopped it. \(message)")
        }
        return .failed(message)
    }

    /// Whether the original path still holds the same entry the scan saw.
    private static func stillInPlace(_ url: URL, fileID: UInt64) -> Bool {
        guard let current = try? GateSystem.identity(of: url) else { return false }
        return current.fileID == fileID
    }

    /// Whether nothing exists at the path any more.
    private static func isGone(_ url: URL) -> Bool {
        do {
            _ = try GateSystem.lstatInfo(of: url)
            return false
        } catch let error as SysError {
            return error.isMissing
        } catch {
            return false
        }
    }

    /// Important-usage available capacity of the volume that holds `url`. Nil when unreadable.
    private static func availableSpace(on url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Holds the open-files snapshot for a run and takes a new one after a number of items or a time.
private struct SnapshotKeeper {
    let source: Cleaner.OpenFilesSource
    let items: Int
    let time: Duration
    private var provider: (any OpenFilesProvider)?
    private var takenAt = ContinuousClock.now
    private var served = 0

    init(source: @escaping Cleaner.OpenFilesSource, items: Int, time: Duration) {
        self.source = source
        self.items = items
        self.time = time
    }

    /// The snapshot to use for the next item.
    mutating func current() async -> any OpenFilesProvider {
        if let provider, served < items, ContinuousClock.now - takenAt < time {
            served += 1
            return provider
        }
        let fresh = await source()
        provider = fresh
        takenAt = ContinuousClock.now
        served = 1
        return fresh
    }
}

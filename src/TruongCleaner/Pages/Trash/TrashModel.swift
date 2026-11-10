import CleanerActions
import CleanerCore
import CleanerScanner
import Foundation
import Observation

/// What a scan of `~/.Trash` found. Plain values only; built off the main actor.
nonisolated struct TrashSnapshot: Sendable {
    /// The `trash.user` rule the findings came from.
    let rule: Rule
    /// The rule's root as it was scanned, for the safety gate.
    let expandedRoots: [URL]
    /// Each direct child of the Trash.
    let findings: [Finding]
    /// Allocated bytes of everything that could be read.
    let allocatedBytes: Int64
    /// True when macOS refused to open the Trash or a folder in it.
    let needsAccess: Bool
    /// True when the scan was stopped early.
    let partial: Bool

    /// Items in the Trash, as Finder counts them.
    var itemCount: Int { findings.count }
}

/// The items that history says TruongCleaner moved to the Trash and has not put back or freed.
nonisolated struct OurTrashItems: Sendable {
    let count: Int
    let bytes: Int64
}

/// Work for the Trash page. Runs off the main actor.
nonisolated enum TrashWork {
    /// The catalog rule that offers the children of `~/.Trash`.
    static let ruleID = "trash.user"

    /// The rule, or nil if the catalog does not have it.
    static func rule() -> Rule? {
        Catalog.all.first { $0.id == ruleID }
    }

    /// Reads the size and children of `~/.Trash` with the scan engine. Nil when the scan was cancelled.
    @concurrent
    static func measure(rule: Rule, environment: CleanerCore.Environment, exclusions: [URL]) async -> TrashSnapshot? {
        let request = ScanRequest(rules: [rule], environment: environment, userExclusions: exclusions)
        var report: ScanReport?
        for await event in await ScanEngine().scan(request) {
            if case .finished(let finished) = event { report = finished }
        }
        guard !Task.isCancelled, let result = report?.results.first(where: { $0.ruleID == rule.id }) else {
            return nil
        }
        let root = environment.home.resolvingSymlinksInPath().appending(path: ".Trash", directoryHint: .isDirectory)
        return TrashSnapshot(
            rule: rule,
            expandedRoots: [root],
            findings: result.findings,
            allocatedBytes: result.measuredBytes,
            needsAccess: !result.needsAccess.isEmpty,
            partial: result.partial
        )
    }

    /// Items from history that are waiting in the Trash. Nil when history cannot be read.
    @concurrent
    static func ourItems(history: HistoryStore) async -> OurTrashItems? {
        guard let items = try? await history.trashedItems() else { return nil }
        return OurTrashItems(count: items.count, bytes: items.reduce(0) { $0 + $1.item.privateBytes })
    }

    /// Deletes for good the items TruongCleaner moved to the Trash, through `UndoService`.
    @concurrent
    static func freeSpace(home: URL, history: HistoryStore) async -> FreeSpaceReport {
        let service = UndoService(trash: Services.trashLocations(home: home))
        return await service.freeSpaceNow(history: history, executor: FileManagerExecutor())
    }

    /// Deletes every child of `~/.Trash` through `Cleaner` and `SafetyGate` with the `trash.user` rule.
    @concurrent
    static func empty(
        _ snapshot: TrashSnapshot, services: Services, environment: CleanerCore.Environment, exclusions: [URL]
    ) async -> CleanReport {
        let items = snapshot.findings.map {
            PlannedItem(finding: $0, rule: snapshot.rule, expandedRoots: snapshot.expandedRoots)
        }
        let plan = CleanPlan(items: items, mode: .permanent, permanentConfirmed: true)
        let cleaner = services.makeCleaner(environment: environment, userExclusions: exclusions)
        return await cleaner.run(plan) { _ in }
    }
}

/// What the last action on the Trash page did, in plain words.
struct TrashActionResult: Equatable {
    /// One sentence.
    let title: String
    /// Details: skipped and failed items with reasons, measured change in free space.
    let lines: [String]
    let isError: Bool
}

/// The Trash page: what is in the Trash, what TruongCleaner put there, and the two ways to free it.
@Observable @MainActor
final class TrashModel {
    enum LoadState {
        case loading
        case loaded(TrashSnapshot)
        case failed(String)
    }

    enum Activity {
        case idle
        case freeing
        case emptying
    }

    /// Which confirmation dialog is open.
    enum Confirmation {
        case freeSpace
        case freeSpaceSecond
        case emptyFirst
        case emptySecond
    }

    private(set) var state: LoadState = .loading
    /// Nil when history could not be read.
    private(set) var ours: OurTrashItems?
    private(set) var activity: Activity = .idle
    private(set) var result: TrashActionResult?
    var confirmation: Confirmation?

    @ObservationIgnored private let services: Services
    @ObservationIgnored private let settings: SettingsStore

    init(services: Services, settings: SettingsStore) {
        self.services = services
        self.settings = settings
    }

    // MARK: What the buttons can do

    /// The loaded snapshot, if there is one.
    var snapshot: TrashSnapshot? {
        if case .loaded(let snapshot) = state { snapshot } else { nil }
    }

    /// Why Free Space Now is off, or nil when it is on.
    var freeSpaceDisabledReason: String? {
        if activity != .idle { return "Wait for the current action to finish" }
        guard let ours else { return "History could not be read" }
        if ours.count == 0 { return "TruongCleaner has not put anything in the Trash" }
        return nil
    }

    /// Why Empty Trash is off, or nil when it is on.
    var emptyDisabledReason: String? {
        if activity != .idle { return "Wait for the current action to finish" }
        guard let snapshot else { return "The Trash has not been read yet" }
        if snapshot.needsAccess { return "TruongCleaner needs Full Disk Access to read the Trash" }
        if snapshot.partial { return "The Trash was only read in part. Check again" }
        if snapshot.itemCount == 0 { return "The Trash is empty" }
        if !settings.isEnabled(snapshot.rule) { return "The Trash rule is turned off in Settings" }
        return nil
    }

    // MARK: Reading

    /// Reads the Trash and history. Called when the page appears and after every action.
    func refresh() async {
        guard let rule = TrashWork.rule() else {
            state = .failed("The Trash rule is missing from this build.")
            return
        }
        let environment = Services.makeEnvironment()
        // Measuring only reads. Cleaning refuses to run when the exclusion list is unreadable.
        let exclusions = await settings.loadedExclusions() ?? []
        async let measured = TrashWork.measure(rule: rule, environment: environment, exclusions: exclusions)
        async let recorded = TrashWork.ourItems(history: services.history)
        let snapshot = await measured
        let items = await recorded
        guard !Task.isCancelled else { return }
        ours = items
        if let snapshot {
            state = .loaded(snapshot)
        } else if case .loading = state {
            state = .failed("The Trash could not be read.")
        }
    }

    // MARK: Actions

    /// Deletes for good the items TruongCleaner moved to the Trash.
    func freeSpaceNow() async {
        guard freeSpaceDisabledReason == nil else { return }
        activity = .freeing
        result = nil
        let home = FileManager.default.homeDirectoryForCurrentUser
        let report = await TrashWork.freeSpace(home: home, history: services.history)
        result = Self.describe(report)
        activity = .idle
        await refresh()
    }

    /// Deletes everything in the Trash for good, through `Cleaner`.
    func emptyTrash() async {
        guard emptyDisabledReason == nil, let snapshot else { return }
        activity = .emptying
        result = nil
        guard let exclusions = await settings.loadedExclusions() else {
            result = TrashActionResult(
                title: "Nothing was deleted",
                lines: ["Your list of excluded folders could not be read, so the Trash was left alone."],
                isError: true)
            activity = .idle
            return
        }
        let report = await TrashWork.empty(
            snapshot, services: services, environment: Services.makeEnvironment(), exclusions: exclusions)
        result = Self.describe(report)
        activity = .idle
        await refresh()
    }

    // MARK: Results

    private static func describe(_ report: FreeSpaceReport) -> TrashActionResult {
        var lines = grouped(report.skipped.map(\.reason), prefix: "Left in the Trash")
        lines += grouped(report.failed.map(\.reason), prefix: "Could not delete")
        let freed = report.freed.count
        let title: String
        if freed == 0 {
            title = "Nothing was deleted"
        } else {
            title = "Deleted \(freed) \(freed == 1 ? "item" : "items") for good, about \(ByteFormatter.string(report.freedBytes))"
        }
        return TrashActionResult(title: title, lines: lines, isError: freed == 0 && !lines.isEmpty)
    }

    private static func describe(_ report: CleanReport) -> TrashActionResult {
        var skipped: [String] = []
        var failed: [String] = []
        var deleted = 0
        for item in report.items {
            switch item.outcome {
            case .deleted: deleted += 1
            case .moved: break
            case .skipped(let reason): skipped.append(reason.userMessage)
            case .failed(let message): failed.append(message)
            }
        }
        var lines = grouped(skipped, prefix: "Left in the Trash")
        lines += grouped(failed, prefix: "Could not delete")
        if let measured = report.measuredFreedBytes {
            let sign = measured < 0 ? "−" : "+"
            lines.append("Available space changed by \(sign)\(ByteFormatter.string(abs(measured))).")
        }
        let title: String
        if deleted == 0 {
            title = "Nothing was deleted"
        } else {
            title = "Deleted \(deleted) \(deleted == 1 ? "item" : "items") for good, about \(ByteFormatter.string(report.estimatedFreedBytes))"
        }
        return TrashActionResult(title: title, lines: lines, isError: deleted == 0 && !(skipped + failed).isEmpty)
    }

    /// "Left in the Trash (3): Used too recently", one line per reason, most common first.
    private static func grouped(_ reasons: [String], prefix: String) -> [String] {
        var counts: [String: Int] = [:]
        for reason in reasons { counts[reason, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\(prefix) (\($0.value)): \($0.key)" }
    }
}

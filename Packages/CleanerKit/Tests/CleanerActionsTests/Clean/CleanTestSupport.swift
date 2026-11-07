import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Synchronization
import Testing

@testable import CleanerActions

/// Moves items into a folder inside the fixture instead of the real Trash. Records every call.
final class FakeTrashExecutor: ItemExecutor, Sendable {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "Fake failure" }
    }

    /// How the fake behaves for one call.
    enum Behavior: Sendable {
        case normal
        case fail
        /// Reports success without moving anything.
        case lie
    }

    let trash: URL
    private let state = Mutex(State())

    private struct State {
        var moved: [URL] = []
        var deleted: [URL] = []
        var behavior: @Sendable (Int) -> Behavior = { _ in .normal }
        var onMove: (@Sendable (Int) -> Void)?
    }

    init(trash: URL) { self.trash = trash }

    var moved: [URL] { state.withLock { $0.moved } }
    var deleted: [URL] { state.withLock { $0.deleted } }
    var callCount: Int { state.withLock { $0.moved.count + $0.deleted.count } }

    /// Chooses the behavior by zero-based move call number.
    func setBehavior(_ behavior: @escaping @Sendable (Int) -> Behavior) {
        state.withLock { $0.behavior = behavior }
    }

    /// Runs after each successful move, with the zero-based call number.
    func setOnMove(_ action: @escaping @Sendable (Int) -> Void) {
        state.withLock { $0.onMove = action }
    }

    func moveToTrash(_ url: URL) async throws -> URL {
        let (index, behavior, hook) = state.withLock { state -> (Int, Behavior, (@Sendable (Int) -> Void)?) in
            state.moved.append(url)
            return (state.moved.count - 1, state.behavior(state.moved.count - 1), state.onMove)
        }
        var destination = trash.appending(path: url.lastPathComponent, directoryHint: .inferFromPath)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = trash.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)", directoryHint: .inferFromPath)
        }
        switch behavior {
        case .fail: throw Failure()
        case .lie: return destination
        case .normal:
            try FileManager.default.moveItem(at: url, to: destination)
            hook?(index)
            return destination
        }
    }

    func deletePermanently(_ url: URL) async throws {
        state.withLock { $0.deleted.append(url) }
        try FileManager.default.removeItem(at: url)
    }
}

/// Answers per file name; everything else gets `fallback`.
struct NamedFiles: OpenFilesProvider {
    var open: Set<String>
    var fallback: Bool? = false

    func hasOpenFiles(under url: URL) async -> Bool? {
        open.contains(url.lastPathComponent) ? true : fallback
    }
}

/// Counts how many snapshots a run asked for.
final class CountingSource: Sendable {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }

    func make(_ provider: any OpenFilesProvider) -> Cleaner.OpenFilesSource {
        { [self] in
            count.withLock { $0 += 1 }
            return provider
        }
    }
}

/// Collects progress events.
final class ProgressLog: Sendable {
    private let events = Mutex<[CleanProgress]>([])
    var all: [CleanProgress] { events.withLock { $0 } }
    func add(_ event: CleanProgress) { events.withLock { $0.append(event) } }
}

/// A fixture home with a Caches rule root, a fake Trash and a history file.
struct CleanHarness {
    let base: GateHarness
    let trash: URL
    let historyFile: URL
    let executor: FakeTrashExecutor
    let history: HistoryStore

    var tree: FixtureTree { base.tree }
    var caches: URL { base.caches }

    init() throws {
        base = try GateHarness()
        trash = try base.tree.addDirectory(".Trash")
        historyFile = base.tree.url(for: "state/history.jsonl")
        executor = FakeTrashExecutor(trash: trash)
        history = HistoryStore(fileURL: historyFile)
    }

    func remove() { base.tree.remove() }

    var trashLocations: TrashLocations { TrashLocations(home: base.home, additionalFolders: [trash]) }
    var undo: UndoService { UndoService(trash: trashLocations) }

    /// Adds a file under Caches and returns a finding with its current identity.
    @discardableResult
    func addCacheFile(_ name: String, size: Int = 100) throws -> PlannedItem {
        let url = try base.tree.addFile("home/Library/Caches/\(name)", size: size)
        return try planned(url)
    }

    /// A planned item for something that already exists, using the default rule.
    func planned(_ url: URL, rule: Rule? = nil, isDirectory: Bool = false) throws -> PlannedItem {
        let identity = try GateSystem.identity(of: url)
        let finding = Finding(
            ruleID: "test.rule",
            url: url,
            fsid: identity.fsid,
            fileID: identity.fileID,
            allocatedBytes: 4096,
            privateBytes: 1024,
            newestModification: nil,
            isDirectory: isDirectory,
            isSymlink: false,
            flags: 0,
            itemCount: 1
        )
        return PlannedItem(finding: finding, rule: rule ?? base.rule(), expandedRoots: [caches])
    }

    /// A cleaner whose gate context comes from the harness. The open-files source defaults to "nothing open".
    func cleaner(
        executor: (any ItemExecutor)? = nil,
        history: HistoryStore? = nil,
        files: any OpenFilesProvider = FakeFiles(answer: false),
        source: Cleaner.OpenFilesSource? = nil,
        refreshItems: Int = 500
    ) -> Cleaner {
        let context = base.context(files: files)
        return Cleaner(
            gate: SafetyGate(),
            executor: executor ?? self.executor,
            history: history ?? self.history,
            context: { _ in context },
            openFilesSource: source ?? { files },
            refreshItems: refreshItems
        )
    }

    func run(_ plan: CleanPlan, cleaner: Cleaner? = nil) async -> CleanReport {
        await (cleaner ?? self.cleaner()).run(plan, progress: { _ in })
    }
}

/// Runs `body` with a fresh harness and removes the fixture afterwards.
func withCleanHarness(_ body: (CleanHarness) async throws -> Void) async throws {
    let harness = try CleanHarness()
    defer { harness.remove() }
    try await body(harness)
}

extension ItemOutcome {
    var movedURL: URL? {
        if case .moved(let url) = self { return url }
        return nil
    }

    var skipReason: DenyReason? {
        if case .skipped(let reason) = self { return reason }
        return nil
    }
}

func exists(_ url: URL) -> Bool {
    (try? GateSystem.lstatInfo(of: url)) != nil
}

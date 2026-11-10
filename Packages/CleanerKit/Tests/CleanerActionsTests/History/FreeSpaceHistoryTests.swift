import CleanerCore
import CleanerTestSupport
import Foundation
import Synchronization
import Testing

@testable import CleanerActions

/// Free Space Now writes a `freeBegin` line before it deletes anything (safety.md rule 11).
struct FreeSpaceHistoryTests {
    private func clean(_ harness: CleanHarness, _ names: [String]) async throws -> CleanReport {
        let items = try names.map { try harness.addCacheFile($0) }
        let report = await harness.run(CleanPlan(items: items))
        for entry in report.items { _ = try #require(entry.outcome.movedURL) }
        return report
    }

    @Test func freeSpaceNow_writesFreeBeginListingTheTrashItemsBeforeTheFirstDelete() async throws {
        try await withCleanHarness { harness in
            let report = try await clean(harness, ["a.bin", "b.bin"])
            let trashed = try report.items.map { try #require($0.outcome.movedURL) }
            #expect(!(try String(contentsOf: harness.historyFile, encoding: .utf8)).contains("freeBegin"))
            let executor = HistoryPeekingExecutor(inner: harness.executor, historyFile: harness.historyFile)

            let result = await harness.undo.freeSpaceNow(history: harness.history, executor: executor)

            #expect(result.freed.count == 2)
            // At the moment of each delete, the freeBegin line was already on disk.
            #expect(executor.sawFreeBeginAtDelete == [true, true])
            let lines = try String(contentsOf: harness.historyFile, encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let beginIndex = try #require(lines.firstIndex { $0.contains("\"type\":\"freeBegin\"") })
            let firstFreed = try #require(lines.firstIndex { $0.contains("\"type\":\"freed\"") })
            #expect(beginIndex < firstFreed)
            let listed = try await harness.history.freeBeginPaths()
            #expect(listed.count == 1)
            #expect(Set(listed[0].map(\.lastPathComponent)) == Set(trashed.map(\.lastPathComponent)))
            #expect(listed[0].count == 2)
            // The new line type changes nothing else in the history.
            #expect(try await harness.history.cleans().count == 1)
            #expect(try await harness.history.followUps().map(\.kind) == [.freed, .freed])
        }
    }

    @Test func freeSpaceNow_deletesNothingWhenFreeBeginCannotBeWritten() async throws {
        try await withCleanHarness { harness in
            let report = try await clean(harness, ["a.bin", "b.bin"])
            let trashed = try report.items.map { try #require($0.outcome.movedURL) }
            // Reading still works; appending does not.
            try harness.tree.setPermissions("state/history.jsonl", mode: 0o400)

            let result = await harness.undo.freeSpaceNow(history: harness.history, executor: harness.executor)

            #expect(result.freed.isEmpty)
            #expect(result.skipped.count == 2)
            #expect(harness.executor.deleted.isEmpty)
            for url in trashed { #expect(exists(url)) }
        }
    }

    @Test func freeSpaceNow_writesNoFreeBeginWhenThereIsNothingToDelete() async throws {
        try await withCleanHarness { harness in
            _ = await harness.undo.freeSpaceNow(history: harness.history, executor: harness.executor)
            #expect(!FileManager.default.fileExists(atPath: harness.historyFile.path(percentEncoded: false)))
        }
    }
}

/// Wraps the fake Trash executor and records, at each delete, whether `freeBegin` is already in the history file.
private final class HistoryPeekingExecutor: ItemExecutor, Sendable {
    private let inner: FakeTrashExecutor
    private let historyFile: URL
    private let seen = Mutex<[Bool]>([])

    init(inner: FakeTrashExecutor, historyFile: URL) {
        self.inner = inner
        self.historyFile = historyFile
    }

    var sawFreeBeginAtDelete: [Bool] { seen.withLock { $0 } }

    func moveToTrash(_ url: URL) async throws -> URL { try await inner.moveToTrash(url) }

    func deletePermanently(_ url: URL) async throws {
        let text = (try? String(contentsOf: historyFile, encoding: .utf8)) ?? ""
        seen.withLock { $0.append(text.contains("\"type\":\"freeBegin\"")) }
        try await inner.deletePermanently(url)
    }
}

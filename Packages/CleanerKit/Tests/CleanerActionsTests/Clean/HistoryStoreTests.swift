import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerActions

struct HistoryStoreTests {
    private func report(id: UUID = UUID(), started: Date, items: [ItemReport] = []) -> CleanReport {
        CleanReport(
            id: id, startedAt: started, finishedAt: started.addingTimeInterval(2), mode: .trash, items: items,
            availableBefore: 100, availableAfter: 150)
    }

    private func itemReport(_ name: String, outcome: ItemOutcome) -> ItemReport {
        ItemReport(
            findingID: UUID(), ruleID: "test.rule", originalPath: URL(filePath: "/fixture/\(name)"), fsid: 1,
            fileID: 2, estimatedBytes: 4096, privateBytes: 1024, outcome: outcome)
    }

    @Test func store_createsFolderAndFileWithPrivatePermissions() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = tree.url(for: "support/TruongCleaner/history.jsonl")
        let store = HistoryStore(fileURL: file)
        try await store.record(itemReport("a", outcome: .deleted), cleanID: UUID())

        var info = stat()
        #expect(stat(file.deletingLastPathComponent().path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(stat(file.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test func store_writesOneJSONObjectPerLineWithATypeField() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = tree.url(for: "history.jsonl")
        let store = HistoryStore(fileURL: file)
        let id = UUID()
        let item = itemReport("a b\nc", outcome: .moved(to: URL(filePath: "/fixture/.Trash/a")))
        try await store.begin(CleanPlan(items: []), id: id)
        try await store.record(item, cleanID: id)
        try await store.finish(report(id: id, started: Date(), items: [item]))
        try await store.recordUndone(findingID: item.findingID, cleanID: id, restoredTo: item.originalPath)
        try await store.recordFreed(findingID: item.findingID, cleanID: id, trashURL: item.originalPath)

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 5)
        let types = try lines.map { line -> String in
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try #require(object["type"] as? String)
        }
        #expect(types == ["begin", "item", "finish", "undone", "freed"])
    }

    @Test func store_listsCleansNewestFirstWithCounts() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))
        let oldID = UUID()
        let newID = UUID()
        let old = Date().addingTimeInterval(-3600)
        let new = Date()
        let moved = itemReport("a", outcome: .moved(to: URL(filePath: "/fixture/.Trash/a")))
        let skipped = itemReport("b", outcome: .skipped(.openFiles))
        let failed = itemReport("c", outcome: .failed("nope"))

        try await store.begin(CleanPlan(items: []), id: oldID, startedAt: old)
        try await store.record(moved, cleanID: oldID)
        try await store.finish(report(id: oldID, started: old, items: [moved]))
        try await store.begin(CleanPlan(items: []), id: newID, startedAt: new)
        try await store.record(skipped, cleanID: newID)
        try await store.record(failed, cleanID: newID)

        let cleans = try await store.cleans()
        #expect(cleans.map(\.id) == [newID, oldID])
        #expect(cleans[0].skippedCount == 1 && cleans[0].failedCount == 1)
        #expect(!cleans[0].isFinished)
        #expect(cleans[1].movedCount == 1 && cleans[1].isFinished)
        #expect(cleans[1].availableBefore == 100 && cleans[1].availableAfter == 150)
        #expect(try await store.items(of: oldID).map(\.findingID) == [moved.findingID])
        #expect(try await store.items(of: UUID()).isEmpty)
    }

    @Test func store_toleratesATruncatedLastLineAndDoesNotGlueTheNextOneToIt() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let file = tree.url(for: "history.jsonl")
        let store = HistoryStore(fileURL: file)
        let id = UUID()
        let first = itemReport("first", outcome: .deleted)
        try await store.begin(CleanPlan(items: []), id: id)
        try await store.record(first, cleanID: id)

        // A crash in the middle of writing the next line.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"item","cleanID":"#.utf8))
        try handle.close()

        #expect(try await store.items(of: id).map(\.findingID) == [first.findingID])

        let second = itemReport("second", outcome: .deleted)
        try await store.record(second, cleanID: id)
        #expect(try await store.items(of: id).map(\.findingID) == [first.findingID, second.findingID])
    }

    @Test func store_missingFileIsAnEmptyHistory() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let store = HistoryStore(fileURL: tree.url(for: "nothing/history.jsonl"))
        #expect(try await store.cleans().isEmpty)
        #expect(try await store.trashedItems().isEmpty)
    }

    @Test func store_outcomesAndReasonsSurviveARoundTrip() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))
        let id = UUID()
        let outcomes: [ItemOutcome] = [
            .moved(to: URL(filePath: "/fixture/.Trash/odd name é")), .deleted, .skipped(.ownerOpen("Slack")),
            .skipped(.protectedPath(.appleData)), .failed("Fake failure"),
        ]
        for outcome in outcomes { try await store.record(itemReport("x", outcome: outcome), cleanID: id) }
        #expect(try await store.items(of: id).map(\.outcome) == outcomes)
    }

    @Test func store_trashedItemsLeavesOutPutBackAndFreedOnes() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let store = HistoryStore(fileURL: tree.url(for: "history.jsonl"))
        let id = UUID()
        let items = ["a", "b", "c"].map { itemReport($0, outcome: .moved(to: URL(filePath: "/fixture/.Trash/\($0)"))) }
        for item in items { try await store.record(item, cleanID: id) }
        try await store.record(itemReport("d", outcome: .deleted), cleanID: id)
        try await store.recordUndone(findingID: items[0].findingID, cleanID: id, restoredTo: items[0].originalPath)
        try await store.recordFreed(findingID: items[1].findingID, cleanID: id, trashURL: URL(filePath: "/fixture/.Trash/b"))

        #expect(try await store.trashedItems().map(\.item.findingID) == [items[2].findingID])
        #expect(try await store.followUps().map(\.kind) == [.undone, .freed])
    }
}

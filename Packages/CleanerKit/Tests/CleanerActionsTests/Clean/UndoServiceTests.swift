import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerActions

struct UndoServiceTests {
    /// Cleans the given files and returns the report.
    private func clean(_ harness: CleanHarness, _ names: [String]) async throws -> (CleanReport, [PlannedItem]) {
        let items = try names.map { try harness.addCacheFile($0) }
        let report = await harness.run(CleanPlan(items: items))
        for entry in report.items { _ = try #require(entry.outcome.movedURL) }
        return (report, items)
    }

    // MARK: Put Back (REQ-CLEAN-04)

    @Test func putBack_restoresAMovedItemAndRecordsIt() async throws {
        try await withCleanHarness { harness in
            let (report, items) = try await clean(harness, ["a.bin"])
            let entry = report.items[0]
            let trashed = try #require(entry.outcome.movedURL)

            let result = await harness.undo.putBack(entry, cleanID: report.id, history: harness.history)

            guard case .restored(let restored) = result else {
                Issue.record("Expected restored, got \(result)")
                return
            }
            #expect(restored.lastPathComponent == "a.bin")
            #expect(exists(items[0].finding.url))
            #expect(!exists(trashed))
            // Same entry as before the clean.
            #expect(try GateSystem.identity(of: restored).fileID == entry.fileID)
            #expect(try await harness.history.followUps().map(\.kind) == [.undone])
            #expect(try await harness.history.trashedItems().isEmpty)
        }
    }

    @Test func putBack_refusesWhenTheItemWasMovedAgain() async throws {
        try await withCleanHarness { harness in
            let (report, items) = try await clean(harness, ["a.bin"])
            let trashed = try #require(report.items[0].outcome.movedURL)
            try FileManager.default.moveItem(at: trashed, to: harness.trash.appending(path: "renamed.bin"))

            let result = await harness.undo.putBack(report.items[0], cleanID: report.id, history: harness.history)
            #expect(result == .refused(.goneFromTrash))
            #expect(!exists(items[0].finding.url))
            #expect(try await harness.history.followUps().isEmpty)
        }
    }

    @Test func putBack_refusesWhenTheOriginalPathIsTaken() async throws {
        try await withCleanHarness { harness in
            let (report, items) = try await clean(harness, ["a.bin"])
            let squatter = try harness.base.tree.addFile("home/Library/Caches/a.bin", size: 7)
            #expect(squatter == items[0].finding.url)
            let trashed = try #require(report.items[0].outcome.movedURL)

            let result = await harness.undo.putBack(report.items[0], cleanID: report.id, history: harness.history)
            #expect(result == .refused(.originalPathTaken))
            #expect(exists(trashed))
            // The newcomer is untouched.
            #expect(try Data(contentsOf: squatter).count == 7)
        }
    }

    @Test func putBack_refusesWhenTheFileIDChanged() async throws {
        try await withCleanHarness { harness in
            let (report, items) = try await clean(harness, ["a.bin"])
            let trashed = try #require(report.items[0].outcome.movedURL)
            // Someone replaced what is at the recorded Trash location.
            try FileManager.default.removeItem(at: trashed)
            try Data(count: 5).write(to: trashed)

            let result = await harness.undo.putBack(report.items[0], cleanID: report.id, history: harness.history)
            #expect(result == .refused(.changedSinceClean))
            #expect(exists(trashed))
            #expect(!exists(items[0].finding.url))
        }
    }

    @Test func putBack_refusesWhenTheOriginalFolderIsGone() async throws {
        try await withCleanHarness { harness in
            let folder = try harness.base.tree.addDirectory("home/Library/Caches/Sub")
            let file = try harness.base.tree.addFile("home/Library/Caches/Sub/a.bin", size: 10)
            let item = try harness.planned(file)
            let report = await harness.run(CleanPlan(items: [item]))
            let trashed = try #require(report.items[0].outcome.movedURL)
            try FileManager.default.removeItem(at: folder)

            let result = await harness.undo.putBack(report.items[0], cleanID: report.id, history: harness.history)
            #expect(result == .refused(.originalFolderMissing))
            #expect(exists(trashed))
        }
    }

    @Test func putBack_refusesAnItemThatIsNotInATrash() async throws {
        try await withCleanHarness { harness in
            // A history entry that claims a move to a place that is not a Trash.
            let stray = try harness.base.tree.addFile("home/stray.bin", size: 3)
            let identity = try GateSystem.identity(of: stray)
            let forged = ItemReport(
                findingID: UUID(), ruleID: "test.rule", originalPath: harness.caches.appending(path: "stray.bin"),
                fsid: identity.fsid, fileID: identity.fileID, estimatedBytes: 0, privateBytes: 0,
                outcome: .moved(to: stray))

            let result = await harness.undo.putBack(forged, cleanID: UUID(), history: harness.history)
            #expect(result == .refused(.outsideTrash))
            #expect(exists(stray))
            #expect(!exists(harness.caches.appending(path: "stray.bin")))
        }
    }

    @Test func putBack_refusesAnItemBehindALinkInsideTheTrash() async throws {
        try await withCleanHarness { harness in
            let elsewhere = try harness.base.tree.addDirectory("elsewhere")
            let file = try harness.base.tree.addFile("elsewhere/a.bin", size: 3)
            // `.Trash/link` points out of the Trash, so `.Trash/link/a.bin` is not directly in it.
            _ = try harness.base.tree.addSymlink(".Trash/link", destination: elsewhere)
            let identity = try GateSystem.identity(of: file)
            let forged = ItemReport(
                findingID: UUID(), ruleID: "test.rule", originalPath: harness.caches.appending(path: "a.bin"),
                fsid: identity.fsid, fileID: identity.fileID, estimatedBytes: 0, privateBytes: 0,
                outcome: .moved(to: harness.trash.appending(path: "link/a.bin")))

            let result = await harness.undo.putBack(forged, cleanID: UUID(), history: harness.history)
            #expect(result == .refused(.outsideTrash))
            #expect(exists(file))
        }
    }

    @Test func putBack_refusesAnItemThatWasNotMoved() async throws {
        try await withCleanHarness { harness in
            let item = try harness.addCacheFile("a.bin")
            let report = await harness.run(
                CleanPlan(items: [item]), cleaner: harness.cleaner(files: FakeFiles(answer: true)))
            #expect(report.items[0].outcome == .skipped(.openFiles))
            let result = await harness.undo.putBack(report.items[0], cleanID: report.id, history: harness.history)
            #expect(result == .refused(.notMoved))
        }
    }

    // MARK: Free Space Now (REQ-CLEAN-05)

    @Test func freeSpaceNow_deletesOnlyItemsThisAppMovedAndLeavesForeignFiles() async throws {
        try await withCleanHarness { harness in
            let (report, _) = try await clean(harness, ["a.bin", "b.bin", "c.bin"])
            let foreign = try harness.base.tree.addFile(".Trash/foreign.txt", size: 9)
            // One item is put back first, so it must not be deleted.
            _ = await harness.undo.putBack(report.items[2], cleanID: report.id, history: harness.history)

            let result = await harness.undo.freeSpaceNow(history: harness.history, executor: harness.executor)

            #expect(result.freed.map(\.findingID) == [report.items[0].findingID, report.items[1].findingID])
            #expect(result.skipped.isEmpty && result.failed.isEmpty)
            #expect(result.freedBytes == 2048)
            #expect(harness.executor.deleted.count == 2)
            for entry in report.items.prefix(2) { #expect(!exists(try #require(entry.outcome.movedURL))) }
            #expect(exists(foreign))
            #expect(exists(report.items[2].originalPath))
            #expect(try await harness.history.followUps().map(\.kind) == [.undone, .freed, .freed])

            // A second call has nothing left to do.
            let again = await harness.undo.freeSpaceNow(history: harness.history, executor: harness.executor)
            #expect(again.freed.isEmpty)
            #expect(harness.executor.deleted.count == 2)
        }
    }

    @Test func freeSpaceNow_skipsAnItemWhoseFileIDChanged() async throws {
        try await withCleanHarness { harness in
            let (report, _) = try await clean(harness, ["a.bin", "b.bin"])
            let first = try #require(report.items[0].outcome.movedURL)
            try FileManager.default.removeItem(at: first)
            try Data(count: 4).write(to: first)

            let result = await harness.undo.freeSpaceNow(history: harness.history, executor: harness.executor)

            #expect(result.freed.map(\.findingID) == [report.items[1].findingID])
            #expect(result.skipped.map(\.item.findingID) == [report.items[0].findingID])
            #expect(exists(first))
            #expect(harness.executor.deleted == [try #require(report.items[1].outcome.movedURL)])
        }
    }

    @Test func freeSpaceNow_ignoresHistoryEntriesPointingOutsideATrash() async throws {
        try await withCleanHarness { harness in
            let stray = try harness.base.tree.addFile("home/precious.bin", size: 3)
            let identity = try GateSystem.identity(of: stray)
            let forged = ItemReport(
                findingID: UUID(), ruleID: "test.rule", originalPath: harness.caches.appending(path: "precious.bin"),
                fsid: identity.fsid, fileID: identity.fileID, estimatedBytes: 0, privateBytes: 0,
                outcome: .moved(to: stray))
            try await harness.history.record(forged, cleanID: UUID())

            let result = await harness.undo.freeSpaceNow(history: harness.history, executor: harness.executor)
            #expect(result.freed.isEmpty)
            #expect(result.skipped.count == 1)
            #expect(harness.executor.deleted.isEmpty)
            #expect(exists(stray))
        }
    }

    @Test func freeSpaceNow_doesNothingWithoutHistory() async throws {
        try await withCleanHarness { harness in
            let foreign = try harness.base.tree.addFile(".Trash/foreign.txt", size: 9)
            let result = await harness.undo.freeSpaceNow(history: harness.history, executor: harness.executor)
            #expect(result.freed.isEmpty && result.skipped.isEmpty)
            #expect(exists(foreign))
        }
    }

    // MARK: Trash locations

    @Test func trashLocations_recognisesTrashFoldersAndNothingElse() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let home = try tree.addDirectory("home")
        _ = try tree.addDirectory("home/.Trash")
        let inTrash = try tree.addFile("home/.Trash/a.bin", size: 1)
        let notTrash = try tree.addFile("home/Documents/a.bin", size: 1)
        let nested = try tree.addFile("home/.Trash/Folder/deep.bin", size: 1)
        let locations = TrashLocations(home: home)

        #expect(locations.contains(inTrash))
        #expect(!locations.contains(notTrash))
        // Only direct children count.
        #expect(!locations.contains(nested))
        // The Trash folder itself is not an item in it.
        #expect(!locations.contains(home.appending(path: ".Trash")))
        #expect(!locations.contains(URL(filePath: "/")))
    }

    @Test(arguments: [
        (["Volumes", "Disk", ".Trashes", "501"], true),
        (["System", "Volumes", "Data", ".Trashes", "501"], true),
        ([".Trashes", "501"], true),
        (["Volumes", "Disk", ".Trashes", "502"], false),
        (["Volumes", "Disk", ".Trashes"], false),
        (["Volumes", "Disk", "Sub", ".Trashes", "501"], false),
        (["Users", "me", ".Trashes", "501"], false),
        (["Volumes", "Disk", "Trashes", "501"], false),
    ] as [([String], Bool)])
    func trashLocations_volumeTrashesMatchByUserID(parts: [String], expected: Bool) {
        #expect(TrashLocations.isVolumeTrash(parts, uid: 501) == expected)
    }
}

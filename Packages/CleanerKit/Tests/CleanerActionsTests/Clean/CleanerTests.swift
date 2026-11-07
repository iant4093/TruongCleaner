import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerActions

struct CleanerTests {
    // MARK: Moving and recording (REQ-CLEAN-01, -03)

    @Test func run_allowedItemsAreMovedAndRecorded() async throws {
        try await withCleanHarness { harness in
            let first = try harness.addCacheFile("a.bin")
            let second = try harness.addCacheFile("b.bin")
            let report = await harness.run(CleanPlan(items: [first, second]))

            #expect(report.items.count == 2)
            for (entry, planned) in zip(report.items, [first, second]) {
                let destination = try #require(entry.outcome.movedURL)
                #expect(destination.deletingLastPathComponent().path == harness.trash.path)
                #expect(exists(destination))
                #expect(!exists(planned.finding.url))
                #expect(entry.fileID == planned.finding.fileID)
                #expect(entry.originalPath == planned.finding.url)
            }
            #expect(harness.executor.moved.count == 2)

            let stored = try await harness.history.items(of: report.id)
            #expect(stored.map(\.findingID) == report.items.map(\.findingID))
            let summary = try #require(await harness.history.cleans().first)
            #expect(summary.id == report.id)
            #expect(summary.isFinished)
            #expect(summary.plannedCount == 2)
            #expect(summary.movedCount == 2)
            #expect(summary.estimatedFreedBytes == 2048)
            #expect(report.estimatedFreedBytes == 2048)
        }
    }

    @Test func run_deniedItemsAreSkippedWithTheGatesReason() async throws {
        try await withCleanHarness { harness in
            let busy = try harness.addCacheFile("busy.bin")
            let fine = try harness.addCacheFile("fine.bin")
            let outside = try harness.base.tree.addFile("home/other.txt", size: 10)
            let strayed = try harness.planned(outside)

            let cleaner = harness.cleaner(files: NamedFiles(open: ["busy.bin"]))
            let report = await harness.run(CleanPlan(items: [busy, fine, strayed]), cleaner: cleaner)

            #expect(report.items[0].outcome == .skipped(.openFiles))
            #expect(report.items[1].outcome.movedURL != nil)
            #expect(report.items[2].outcome == .skipped(.outsideRoots))
            #expect(exists(busy.finding.url))
            #expect(exists(outside))
            #expect(harness.executor.moved == [fine.finding.url])

            // Skips are in history with their reasons, so the result list can show them after a restart.
            let stored = try await harness.history.items(of: report.id)
            #expect(stored[0].outcome == .skipped(.openFiles))
            #expect(stored[2].outcome == .skipped(.outsideRoots))
        }
    }

    @Test func run_infoRuleNeverActs() async throws {
        try await withCleanHarness { harness in
            let file = try harness.base.tree.addFile("home/Library/Caches/info.bin", size: 10)
            let item = try harness.planned(file, rule: harness.base.rule(tier: .info, action: .none))
            let report = await harness.run(CleanPlan(items: [item]))
            #expect(report.items[0].outcome == .skipped(.infoRule))
            #expect(harness.executor.callCount == 0)
            #expect(exists(file))
        }
    }

    @Test func run_ownerCommandRuleIsNotRunAsAFileAction() async throws {
        try await withCleanHarness { harness in
            let file = try harness.base.tree.addFile("home/Library/Caches/cmd.bin", size: 10)
            let command = OwnerCommandSpec(executable: URL(filePath: "/usr/bin/true"), arguments: [], timeout: .seconds(1))
            let item = try harness.planned(file, rule: harness.base.rule(action: .ownerCommand(command)))
            for mode in [DeleteMode.trash, .permanent] {
                let report = await harness.run(CleanPlan(items: [item], mode: mode, permanentConfirmed: true))
                #expect(report.items[0].outcome.skipReason != nil)
            }
            #expect(harness.executor.callCount == 0)
            #expect(exists(file))
        }
    }

    // MARK: Failures

    @Test func run_executorFailureIsReportedAndTheRunContinues() async throws {
        try await withCleanHarness { harness in
            let first = try harness.addCacheFile("a.bin")
            let second = try harness.addCacheFile("b.bin")
            harness.executor.setBehavior { $0 == 0 ? .fail : .normal }
            let report = await harness.run(CleanPlan(items: [first, second]))

            #expect(report.items[0].outcome == .failed("Fake failure"))
            #expect(exists(first.finding.url))
            #expect(report.items[1].outcome.movedURL != nil)
        }
    }

    @Test func run_aMoveThatDidNotHappenIsNeverReportedAsMoved() async throws {
        try await withCleanHarness { harness in
            let item = try harness.addCacheFile("liar.bin")
            harness.executor.setBehavior { _ in .lie }
            let report = await harness.run(CleanPlan(items: [item]))

            #expect(report.items[0].outcome == .failed("The item is still in place"))
            #expect(exists(item.finding.url))
        }
    }

    @Test func run_historyThatCannotBeOpenedStopsTheRunBeforeAnythingMoves() async throws {
        try await withCleanHarness { harness in
            let blocker = try harness.base.tree.addFile("blocker", size: 1)
            // The history folder would have to be inside a regular file.
            let broken = HistoryStore(fileURL: blocker.appending(path: "folder/history.jsonl"))
            let first = try harness.addCacheFile("a.bin")
            let second = try harness.addCacheFile("b.bin")
            let report = await harness.run(CleanPlan(items: [first, second]), cleaner: harness.cleaner(history: broken))

            for entry in report.items { #expect(entry.outcome == .skipped(.probeFailed("history unavailable"))) }
            #expect(harness.executor.callCount == 0)
            #expect(exists(first.finding.url) && exists(second.finding.url))
        }
    }

    @Test func run_historyThatFailsMidRunStopsTheRestAndKeepsTheTruth() async throws {
        try await withCleanHarness { harness in
            let items = [
                try harness.addCacheFile("a.bin"), try harness.addCacheFile("b.bin"), try harness.addCacheFile("c.bin"),
            ]
            // After the first item moves, make the history file read-only so its record cannot be written.
            let file = harness.historyFile.path(percentEncoded: false)
            harness.executor.setOnMove { index in if index == 0 { _ = chmod(file, 0o400) } }
            let report = await harness.run(CleanPlan(items: items))

            // The first item did move, so it is reported as moved even though its record failed.
            #expect(report.items[0].outcome.movedURL != nil)
            #expect(report.items[1].outcome == .skipped(.probeFailed("history unavailable")))
            #expect(report.items[2].outcome == .skipped(.probeFailed("history unavailable")))
            #expect(harness.executor.moved.count == 1)
            #expect(exists(items[1].finding.url) && exists(items[2].finding.url))
            // The plan, written before anything moved, names the item that has no record line.
            let summary = try #require(await harness.history.cleans().first)
            #expect(summary.plannedCount == 3)
            #expect(summary.movedCount == 0)
            #expect(!summary.isFinished)
        }
    }

    @Test func run_cancelledRunSkipsEverythingAndKeepsTheFiles() async throws {
        try await withCleanHarness { harness in
            let item = try harness.addCacheFile("a.bin")
            let cleaner = harness.cleaner()
            let plan = CleanPlan(items: [item])
            let task = Task {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return await cleaner.run(plan, progress: { _ in })
            }
            task.cancel()
            let report = await task.value
            #expect(report.items[0].outcome == .skipped(.probeFailed("cancelled")))
            #expect(harness.executor.callCount == 0)
            #expect(exists(item.finding.url))
        }
    }

    // MARK: Permanent delete (REQ-CLEAN-02)

    @Test func run_permanentWithoutConfirmationIsRefusedAndTheExecutorNeverRuns() async throws {
        try await withCleanHarness { harness in
            let first = try harness.addCacheFile("a.bin")
            let second = try harness.addCacheFile("b.bin")
            let plan = CleanPlan(items: [first, second], mode: .permanent, permanentConfirmed: false)
            let report = await harness.run(plan)

            for entry in report.items {
                #expect(entry.outcome == .skipped(.probeFailed("permanent delete not confirmed")))
            }
            #expect(harness.executor.callCount == 0)
            #expect(exists(first.finding.url) && exists(second.finding.url))

            let verdicts = await harness.cleaner().preview(plan)
            #expect(verdicts[first.finding.id] == .deny(.probeFailed("permanent delete not confirmed")))
        }
    }

    @Test func run_confirmedPermanentDeletesAndRecordsIt() async throws {
        try await withCleanHarness { harness in
            let item = try harness.addCacheFile("gone.bin")
            let report = await harness.run(CleanPlan(items: [item], mode: .permanent, permanentConfirmed: true))

            #expect(report.mode == .permanent)
            #expect(report.items[0].outcome == .deleted)
            #expect(!exists(item.finding.url))
            #expect(harness.executor.deleted == [item.finding.url])
            #expect(harness.executor.moved.isEmpty)
            let summary = try #require(await harness.history.cleans().first)
            #expect(summary.mode == .permanent && summary.deletedCount == 1)
        }
    }

    // MARK: Order

    @Test func run_childOfAMovedParentIsReportedGone() async throws {
        try await withCleanHarness { harness in
            let folder = try harness.base.tree.addDirectory("home/Library/Caches/Parent")
            let child = try harness.base.tree.addFile("home/Library/Caches/Parent/child.bin", size: 10)
            let parent = try harness.planned(folder, isDirectory: true)
            let inner = try harness.planned(child)
            let report = await harness.run(CleanPlan(items: [parent, inner]))

            #expect(report.items[0].outcome.movedURL != nil)
            #expect(report.items[1].outcome == .skipped(.missing))
            #expect(harness.executor.moved == [folder])
            // The child went with its parent.
            let destination = try #require(report.items[0].outcome.movedURL)
            #expect(exists(destination.appending(path: "child.bin")))
        }
    }

    // MARK: Preview equals run (safety rule 15)

    @Test func preview_showsTheVerdictsRunWillUse() async throws {
        try await withCleanHarness { harness in
            let busy = try harness.addCacheFile("busy.bin")
            let fine = try harness.addCacheFile("fine.bin")
            let outside = try harness.planned(try harness.base.tree.addFile("home/other.txt", size: 10))
            let plan = CleanPlan(items: [busy, fine, outside])
            let cleaner = harness.cleaner(files: NamedFiles(open: ["busy.bin"]))

            let verdicts = await cleaner.preview(plan)
            // Preview changes nothing.
            #expect(harness.executor.callCount == 0)
            #expect(exists(busy.finding.url) && exists(fine.finding.url))
            #expect(verdicts.count == 3)

            let report = await cleaner.run(plan, progress: { _ in })
            for entry in report.items {
                let verdict = try #require(verdicts[entry.findingID])
                switch verdict {
                case .allow: #expect(entry.outcome.movedURL != nil)
                case .deny(let reason): #expect(entry.outcome == .skipped(reason))
                }
            }
            #expect(verdicts[busy.finding.id] == .deny(.openFiles))
            #expect(verdicts[fine.finding.id] == .allow)
            #expect(verdicts[outside.finding.id] == .deny(.outsideRoots))
        }
    }

    // MARK: Open-files snapshot per run

    @Test func run_usesItsOwnSnapshotInsteadOfTheContextsProvider() async throws {
        try await withCleanHarness { harness in
            let item = try harness.addCacheFile("a.bin")
            // The context says "open"; the run's snapshot says "closed". The snapshot wins.
            let source = CountingSource()
            let cleaner = harness.cleaner(files: FakeFiles(answer: true), source: source.make(FakeFiles(answer: false)))
            let report = await harness.run(CleanPlan(items: [item]), cleaner: cleaner)
            #expect(report.items[0].outcome.movedURL != nil)
            #expect(source.calls == 1)
        }
    }

    @Test func run_takesANewSnapshotAfterTheConfiguredNumberOfItems() async throws {
        try await withCleanHarness { harness in
            let items = try (0..<5).map { try harness.addCacheFile("f\($0).bin") }
            let source = CountingSource()
            let cleaner = harness.cleaner(source: source.make(FakeFiles(answer: false)), refreshItems: 2)
            _ = await harness.run(CleanPlan(items: items), cleaner: cleaner)
            // Items 1-2, 3-4 and 5 each get their own snapshot.
            #expect(source.calls == 3)
        }
    }

    @Test func run_aFailedSnapshotKeepsEveryItem() async throws {
        try await withCleanHarness { harness in
            let item = try harness.addCacheFile("a.bin")
            let cleaner = harness.cleaner(source: { OpenFilesSnapshot.failed })
            let report = await harness.run(CleanPlan(items: [item]), cleaner: cleaner)
            #expect(report.items[0].outcome == .skipped(.openFilesUnknown))
            #expect(exists(item.finding.url))
        }
    }

    // MARK: Report details (REQ-CLEAN-06)

    @Test func run_measuresAvailableSpaceBeforeAndAfter() async throws {
        try await withCleanHarness { harness in
            let item = try harness.addCacheFile("a.bin")
            let report = await harness.run(CleanPlan(items: [item]))
            let before = try #require(report.availableBefore)
            let after = try #require(report.availableAfter)
            #expect(before > 0 && after > 0)
            #expect(report.measuredFreedBytes == after - before)
        }
    }

    @Test func report_measuredChangeIsNilWhenEitherReadingIsMissing() {
        let base = CleanReport(
            id: UUID(), startedAt: Date(), finishedAt: Date(), mode: .trash, items: [], availableBefore: 10,
            availableAfter: nil)
        #expect(base.measuredFreedBytes == nil)
    }

    @Test func run_reportsProgressForEveryItemAndAtTheEnd() async throws {
        try await withCleanHarness { harness in
            let items = [try harness.addCacheFile("a.bin"), try harness.addCacheFile("b.bin")]
            let log = ProgressLog()
            _ = await harness.cleaner().run(CleanPlan(items: items), progress: { log.add($0) })
            let events = log.all
            #expect(events.map(\.done) == [0, 1, 2])
            #expect(events.allSatisfy { $0.total == 2 })
            #expect(events.last?.current == nil)
            #expect(events.first?.current == items[0].finding.url)
        }
    }

    @Test func run_emptyPlanFinishesWithAnEmptyReport() async throws {
        try await withCleanHarness { harness in
            let report = await harness.run(CleanPlan(items: []))
            #expect(report.items.isEmpty)
            let cleans = try await harness.history.cleans()
            #expect(cleans.first?.isFinished == true)
        }
    }
}

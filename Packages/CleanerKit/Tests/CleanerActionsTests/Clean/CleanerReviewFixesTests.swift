import CleanerCore
import CleanerTestSupport
import Darwin
import Foundation
import Testing

@testable import CleanerActions

/// Pre-v1.0 safety review, findings 2 and 17: the executor acts on the URL the gate verified, the
/// identity is read again right before acting, and a permanent delete that stops partway says so.
struct CleanerReviewFixesTests {
    // MARK: Finding 2

    @Test func executorGetsTheVerifiedURLNotThePathAsScanned() async throws {
        try await withCleanHarness { harness in
            let file = try harness.tree.addFile("home/Library/Caches/a.bin", size: 10)
            // The scan reached the Caches folder through a link, so the finding carries the link's path.
            let alias = try harness.tree.addSymlink("home/alias", destination: harness.caches)
            let given = alias.appending(path: "a.bin")
            let identity = try GateSystem.identity(of: file)
            let finding = Finding(
                ruleID: "test.rule", url: given, fsid: identity.fsid, fileID: identity.fileID,
                allocatedBytes: 4096, privateBytes: 4096, newestModification: nil, isDirectory: false,
                isSymlink: false, flags: 0, itemCount: 1)
            let item = PlannedItem(finding: finding, rule: harness.base.rule(), expandedRoots: [alias])
            let context = harness.base.context(roots: [alias])
            let cleaner = Cleaner(
                gate: SafetyGate(), executor: harness.executor, history: harness.history,
                context: { _ in context }, openFilesSource: { FakeFiles(answer: false) })

            let report = await cleaner.run(CleanPlan(items: [item]), progress: { _ in })

            let real = try GateSystem.realPath(of: harness.caches).appending(path: "a.bin")
            #expect(report.items.first?.outcome.movedURL != nil)
            #expect(harness.executor.moved.map { $0.path(percentEncoded: false) } == [real.path(percentEncoded: false)])
            // History keeps the path the user saw.
            #expect(report.items.first?.originalPath == given)
        }
    }

    private func finding(of url: URL, fileIDOffset: UInt64 = 0, fsidOffset: UInt64 = 0) throws -> Finding {
        let identity = try GateSystem.identity(of: url)
        return Finding(
            ruleID: "test.rule", url: url, fsid: identity.fsid &+ fsidOffset, fileID: identity.fileID &+ fileIDOffset,
            allocatedBytes: 0, privateBytes: 0, newestModification: nil, isDirectory: false, isSymlink: false,
            flags: 0, itemCount: 1)
    }

    @Test func recheck_theSameEntryPasses() async throws {
        try await withCleanHarness { harness in
            let file = try harness.tree.addFile("home/Library/Caches/a.bin", size: 1)
            #expect(Cleaner.recheck(file, against: try finding(of: file)) == nil)
        }
    }

    @Test func recheck_aDifferentFileIDIsChangedSinceScan() async throws {
        try await withCleanHarness { harness in
            let file = try harness.tree.addFile("home/Library/Caches/a.bin", size: 1)
            #expect(Cleaner.recheck(file, against: try finding(of: file, fileIDOffset: 1)) == .changedSinceScan)
        }
    }

    @Test func recheck_aDifferentFileSystemIsChangedSinceScan() async throws {
        try await withCleanHarness { harness in
            let file = try harness.tree.addFile("home/Library/Caches/a.bin", size: 1)
            #expect(Cleaner.recheck(file, against: try finding(of: file, fsidOffset: 1)) == .changedSinceScan)
        }
    }

    @Test func recheck_anItemThatIsGoneIsMissing() async throws {
        try await withCleanHarness { harness in
            let file = try harness.tree.addFile("home/Library/Caches/a.bin", size: 1)
            let scanned = try finding(of: file)
            try FileManager.default.removeItem(at: file)
            #expect(Cleaner.recheck(file, against: scanned) == .missing)
        }
    }

    @Test func recheck_aReplacedEntryWithTheSameNameIsChanged() async throws {
        try await withCleanHarness { harness in
            let folder = try harness.tree.addDirectory("home/Library/Caches/victim")
            let scanned = try finding(of: folder)
            try FileManager.default.moveItem(at: folder, to: harness.caches.appending(path: "victim-old"))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            #expect(Cleaner.recheck(folder, against: scanned) == .changedSinceScan)
        }
    }

    // MARK: Finding 17

    /// Deletes some entries inside the folder, then fails, like `removeItem` stopping at a protected file.
    private final class PartialExecutor: ItemExecutor, Sendable {
        struct Failure: Error, LocalizedError {
            var errorDescription: String? { "Operation not permitted" }
        }

        let removeBeforeFailing: @Sendable (URL) -> Void

        init(removeBeforeFailing: @escaping @Sendable (URL) -> Void) {
            self.removeBeforeFailing = removeBeforeFailing
        }

        func moveToTrash(_ url: URL) async throws -> URL { throw Failure() }

        func deletePermanently(_ url: URL) async throws {
            removeBeforeFailing(url)
            throw Failure()
        }
    }

    private func permanentRun(
        _ harness: CleanHarness, folder: URL, removing: @escaping @Sendable (URL) -> Void
    ) async throws -> CleanReport {
        let item = try harness.planned(folder, isDirectory: true)
        let cleaner = harness.cleaner(executor: PartialExecutor(removeBeforeFailing: removing))
        return await cleaner.run(CleanPlan(items: [item], mode: .permanent, permanentConfirmed: true), progress: { _ in })
    }

    private func message(of report: CleanReport) -> String? {
        if case .failed(let text)? = report.items.first?.outcome { return text }
        return nil
    }

    @Test func permanentDelete_aFolderThatLostEntriesBeforeFailingIsReportedAsPartlyDeleted() async throws {
        try await withCleanHarness { harness in
            let folder = try harness.tree.addDirectory("home/Library/Caches/proj")
            for name in ["a", "b", "c", "d"] { try harness.tree.addFile("home/Library/Caches/proj/\(name)", size: 10) }
            let report = try await permanentRun(harness, folder: folder) { url in
                try? FileManager.default.removeItem(at: url.appending(path: "a"))
                try? FileManager.default.removeItem(at: url.appending(path: "b"))
            }
            let text = try #require(message(of: report))
            #expect(text.hasPrefix("Partly deleted"))
            #expect(text.contains("2 of"))
            #expect(text.contains("Operation not permitted"))
            #expect(exists(folder))
            #expect(report.items.first?.didRemove == false)
        }
    }

    @Test func permanentDelete_theHistoryRecordsThePartialFailure() async throws {
        try await withCleanHarness { harness in
            let folder = try harness.tree.addDirectory("home/Library/Caches/proj")
            for name in ["a", "b"] { try harness.tree.addFile("home/Library/Caches/proj/\(name)", size: 10) }
            _ = try await permanentRun(harness, folder: folder) { url in
                try? FileManager.default.removeItem(at: url.appending(path: "a"))
            }
            let history = try String(contentsOf: harness.historyFile, encoding: .utf8)
            #expect(history.contains("Partly deleted"))
        }
    }

    @Test func permanentDelete_aFailureThatChangedNothingIsAPlainFailure() async throws {
        try await withCleanHarness { harness in
            let folder = try harness.tree.addDirectory("home/Library/Caches/proj")
            try harness.tree.addFile("home/Library/Caches/proj/a", size: 10)
            let report = try await permanentRun(harness, folder: folder) { _ in }
            #expect(message(of: report) == "Operation not permitted")
        }
    }

    @Test func permanentDelete_aFolderThatIsGoneAfterTheErrorIsAPlainFailure() async throws {
        try await withCleanHarness { harness in
            let folder = try harness.tree.addDirectory("home/Library/Caches/proj")
            try harness.tree.addFile("home/Library/Caches/proj/a", size: 10)
            let report = try await permanentRun(harness, folder: folder) { url in
                try? FileManager.default.removeItem(at: url)
            }
            let text = try #require(message(of: report))
            #expect(!text.contains("Partly"))
            #expect(!exists(folder))
        }
    }

    @Test func permanentDelete_aFileThatFailsIsAPlainFailure() async throws {
        try await withCleanHarness { harness in
            let file = try harness.tree.addFile("home/Library/Caches/one.bin", size: 10)
            let item = try harness.planned(file)
            let cleaner = harness.cleaner(executor: PartialExecutor(removeBeforeFailing: { _ in }))
            let report = await cleaner.run(
                CleanPlan(items: [item], mode: .permanent, permanentConfirmed: true), progress: { _ in })
            #expect(message(of: report) == "Operation not permitted")
        }
    }
}

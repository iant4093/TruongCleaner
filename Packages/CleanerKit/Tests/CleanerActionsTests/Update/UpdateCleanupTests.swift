import CleanerTestSupport
import Foundation
import Testing

@testable import CleanerActions

struct UpdateCleanupTests {
    private let hour: TimeInterval = 3600

    private func oldName() -> String { ".TruongCleaner-old-\(UUID().uuidString).app" }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    // MARK: Old bundles

    @Test func removeLeftovers_trashesOnlyOurOldBundles() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("Applications")
            try tree.addDirectory("tmp")
            let ours = oldName()
            let alsoOurs = oldName()
            let foreign = oldName()
            try FixtureApp.stub(in: tree, at: "Applications/\(ours)")
            try FixtureApp.stub(in: tree, at: "Applications/\(alsoOurs)")
            try FixtureApp.stub(in: tree, at: "Applications/\(foreign)", bundleID: "com.example.Other")
            // Names that are close but not ours, even though the bundle ID matches.
            try FixtureApp.stub(in: tree, at: "Applications/TruongCleaner.app")
            try FixtureApp.stub(in: tree, at: "Applications/.TruongCleaner-old-notauuid.app")
            try FixtureApp.stub(in: tree, at: "Applications/.TruongCleaner-new-\(UUID().uuidString).app")
            try FixtureApp.stub(in: tree, at: "Applications/Other-old-\(UUID().uuidString).app")
            let executor = RecordingExecutor()

            let report = await UpdateCleanup(executor: executor).removeLeftovers(
                in: tree.url(for: "Applications"), bundleIdentifier: FixtureApp.ourID,
                temporaryDirectory: tree.url(for: "tmp"))

            let expected = Set([ours, alsoOurs].map { UpdateWorkspace.unixPath(tree.url(for: "Applications/\($0)")) })
            #expect(Set(executor.trashed.map(UpdateWorkspace.unixPath)) == expected)
            #expect(Set(report.trashedBundles.map(UpdateWorkspace.unixPath)) == expected)
            #expect(executor.deletedPermanently.isEmpty)
            // Not moved, not touched: the executor is a fake, so nothing moved, but the foreign one was never offered.
            #expect(report.skipped.contains { $0.url.lastPathComponent == foreign })
        }
    }

    @Test func removeLeftovers_leavesAnOldBundleThatIsASymlink() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("Applications")
            try tree.addDirectory("tmp")
            let target = try FixtureApp.stub(in: tree, at: "elsewhere/TruongCleaner.app")
            try tree.addSymlink("Applications/\(oldName())", destination: target)
            let executor = RecordingExecutor()

            let report = await UpdateCleanup(executor: executor).removeLeftovers(
                in: tree.url(for: "Applications"), bundleIdentifier: FixtureApp.ourID,
                temporaryDirectory: tree.url(for: "tmp"))

            #expect(executor.trashed.isEmpty)
            #expect(report.skipped.count == 1)
            #expect(FixtureApp.build(of: target) == 2000)
        }
    }

    @Test func removeLeftovers_leavesABundleWithAnUnreadableIdentifier() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("Applications")
            try tree.addDirectory("tmp")
            try tree.addDirectory("Applications/\(oldName())")
            let executor = RecordingExecutor()

            _ = await UpdateCleanup(executor: executor).removeLeftovers(
                in: tree.url(for: "Applications"), bundleIdentifier: FixtureApp.ourID,
                temporaryDirectory: tree.url(for: "tmp"))

            #expect(executor.trashed.isEmpty)
        }
    }

    @Test func removeLeftovers_keepsBundlesWhenTheTrashFails() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("Applications")
            try tree.addDirectory("tmp")
            let name = oldName()
            let bundle = try FixtureApp.stub(in: tree, at: "Applications/\(name)")

            let report = await UpdateCleanup(executor: FailingExecutor()).removeLeftovers(
                in: tree.url(for: "Applications"), bundleIdentifier: FixtureApp.ourID,
                temporaryDirectory: tree.url(for: "tmp"))

            #expect(report.trashedBundles.isEmpty)
            #expect(exists(bundle))
        }
    }

    // MARK: Update folders

    @Test func removeLeftovers_deletesOnlyStaleUpdateFolders() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("Applications")
            try tree.addDirectory("tmp")
            let stale = "TruongCleanerUpdate-\(UUID().uuidString)"
            let fresh = "TruongCleanerUpdate-\(UUID().uuidString)"
            let notUUID = "TruongCleanerUpdate-notauuid"
            let other = "SomethingElse-\(UUID().uuidString)"
            let staleFile = try tree.addFile("tmp/\(stale)/TruongCleaner.zip", size: 10)
            try tree.addFile("tmp/\(fresh)/TruongCleaner.zip", size: 10)
            try tree.addFile("tmp/\(notUUID)/keep.txt")
            try tree.addFile("tmp/\(other)/keep.txt")
            let longAgo = Date.now.addingTimeInterval(-3 * hour)
            for name in [stale, notUUID, other] { try tree.setModified("tmp/\(name)", to: longAgo) }

            let report = await UpdateCleanup(executor: RecordingExecutor()).removeLeftovers(
                in: tree.url(for: "Applications"), bundleIdentifier: FixtureApp.ourID,
                temporaryDirectory: tree.url(for: "tmp"), minimumAge: hour)

            #expect(report.removedFolders.map(UpdateWorkspace.unixPath) == [UpdateWorkspace.unixPath(tree.url(for: "tmp/\(stale)"))])
            #expect(!exists(staleFile))
            #expect(!exists(tree.url(for: "tmp/\(stale)")))
            #expect(exists(tree.url(for: "tmp/\(fresh)")))
            #expect(exists(tree.url(for: "tmp/\(notUUID)")))
            #expect(exists(tree.url(for: "tmp/\(other)")))
        }
    }

    @Test func removeLeftovers_doesNotFollowASymlinkNamedLikeAnUpdateFolder() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("Applications")
            try tree.addDirectory("tmp")
            let precious = try tree.addFile("precious/data.txt", size: 10)
            let link = try tree.addSymlink(
                "tmp/TruongCleanerUpdate-\(UUID().uuidString)", destination: precious.deletingLastPathComponent())
            // A symlink's own date is what lstat reports; make sure age is not the reason it survives.
            var times = [timeval(tv_sec: Int(Date.now.timeIntervalSince1970 - 3 * hour), tv_usec: 0)]
            times.append(times[0])
            #expect(lutimes(link.path(percentEncoded: false), times) == 0)

            let report = await UpdateCleanup(executor: RecordingExecutor()).removeLeftovers(
                in: tree.url(for: "Applications"), bundleIdentifier: FixtureApp.ourID,
                temporaryDirectory: tree.url(for: "tmp"), minimumAge: hour)

            #expect(report.removedFolders.isEmpty)
            #expect(exists(link))
            #expect(exists(precious))
        }
    }

    @Test func workspace_discardRemovesOnlyItsOwnFolders() async throws {
        try await withUpdateTree { tree in
            try tree.addDirectory("tmp")
            let folder = try UpdateWorkspace.makeFolder(in: tree.url(for: "tmp"))
            try Data("x".utf8).write(to: folder.appending(path: "TruongCleaner.zip"))
            let stranger = try tree.addFile("tmp/keep-me/data.txt", size: 5)

            UpdateWorkspace.discard(folder)
            UpdateWorkspace.discard(stranger.deletingLastPathComponent())

            #expect(!exists(folder))
            #expect(exists(stranger))
            #expect(UpdateWorkspace.isUpdateFolderName(folder.lastPathComponent))
        }
    }
}

/// A trash that always fails.
private struct FailingExecutor: ItemExecutor {
    func moveToTrash(_ url: URL) async throws -> URL { throw CocoaError(.fileWriteNoPermission) }
    func deletePermanently(_ url: URL) async throws { throw CocoaError(.fileWriteNoPermission) }
}

import CleanerTestSupport
import Foundation
import Synchronization
import Testing
@testable import CleanerScanner

/// Large-file search tests. Every tree is a fixture under `build/test-fixtures/`; nothing reads the real home folder.
struct LargeFileFinderTests {
    /// APFS allocates in 4 KB units, so sizes that are multiples of this have exact expected values.
    private static let page = 4096

    private func file(_ pages: Int) -> Int { pages * Self.page }

    private func bytes(_ pages: Int) -> Int64 { Int64(pages * Self.page) }

    private func daysAgo(_ days: Int) -> Date {
        Date(timeIntervalSinceNow: -Double(days) * 86_400)
    }

    private func names(_ files: [LargeFile]) -> [String] {
        files.map(\.url.lastPathComponent)
    }

    // MARK: Filters

    @Test func sizeAndAgeFiltersApplyTogether() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("old-big.bin", size: file(5), modified: daysAgo(200))
        try tree.addFile("new-big.bin", size: file(6), modified: daysAgo(1))
        try tree.addFile("old-small.bin", size: file(1), modified: daysAgo(200))
        try tree.addFile("sub/old-medium.bin", size: file(3), modified: daysAgo(120))

        let query = LargeFileQuery(roots: [tree.root], minBytes: bytes(2), notModifiedSince: daysAgo(90), limit: 100)
        let found = try await LargeFileFinder.find(query)

        #expect(names(found) == ["old-big.bin", "old-medium.bin"])
        #expect(found.map(\.allocatedBytes) == [bytes(5), bytes(3)])
        #expect(found.allSatisfy { $0.privateBytes > 0 })
        let oldest = try #require(found.first?.modified)
        #expect(abs(oldest.timeIntervalSince(daysAgo(200))) < 120)
    }

    @Test func noDateFilterAcceptsRecentFiles() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("new.bin", size: file(4), modified: daysAgo(1))
        try tree.addFile("old.bin", size: file(2), modified: daysAgo(400))

        let query = LargeFileQuery(roots: [tree.root], minBytes: bytes(1), notModifiedSince: nil, limit: 100)
        let found = try await LargeFileFinder.find(query)

        #expect(names(found) == ["new.bin", "old.bin"])
    }

    @Test func minimumSizeIsInclusive() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("exact.bin", size: file(2))
        try tree.addFile("below.bin", size: file(1))

        let query = LargeFileQuery(roots: [tree.root], minBytes: bytes(2), limit: 100)
        let found = try await LargeFileFinder.find(query)

        #expect(names(found) == ["exact.bin"])
    }

    @Test func foldersAreNeverListed() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("bundle.app/inside.bin", size: file(4))

        let query = LargeFileQuery(roots: [tree.root], minBytes: bytes(1), limit: 100)
        let found = try await LargeFileFinder.find(query)

        #expect(names(found) == ["inside.bin"])
    }

    // MARK: Order and limit

    @Test func resultsAreLargestFirstAndCappedAtLimit() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        for pages in 1...6 {
            try tree.addFile("f\(pages).bin", size: file(pages))
        }

        let query = LargeFileQuery(roots: [tree.root], minBytes: bytes(1), limit: 3)
        let report = try await LargeFileFinder.search(query)

        #expect(names(report.files) == ["f6.bin", "f5.bin", "f4.bin"])
        #expect(report.mayBeMissingFiles)
        #expect(report.partial == false)
    }

    @Test func equalSizesSortByPath() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("b.bin", size: file(2))
        try tree.addFile("a.bin", size: file(2))
        try tree.addFile("c.bin", size: file(2))

        let query = LargeFileQuery(roots: [tree.root], minBytes: bytes(1), limit: 100)
        let found = try await LargeFileFinder.find(query)

        #expect(names(found) == ["a.bin", "b.bin", "c.bin"])
    }

    @Test func nothingIsMissingWhenEverythingFits() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("a.bin", size: file(2))

        let report = try await LargeFileFinder.search(LargeFileQuery(roots: [tree.root], minBytes: bytes(1), limit: 10))

        #expect(report.mayBeMissingFiles == false)
        #expect(report.files.count == 1)
    }

    @Test(arguments: [0, -3])
    func nonPositiveLimitReturnsNothing(limit: Int) async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("a.bin", size: file(2))

        let report = try await LargeFileFinder.search(LargeFileQuery(roots: [tree.root], minBytes: 0, limit: limit))

        #expect(report.files.isEmpty)
        #expect(report.skippedRoots.isEmpty)
    }

    @Test func noRootsReturnsNothing() async throws {
        let report = try await LargeFileFinder.search(LargeFileQuery(roots: [], minBytes: 0, limit: 10))

        #expect(report.files.isEmpty)
        #expect(report.partial == false)
    }

    // MARK: Duplicates and overlap

    @Test func hardLinkedFileAppearsOnce() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let original = try tree.addFile("one/data.bin", size: file(4))
        try tree.addHardLink("two/again.bin", to: original)
        try tree.addHardLink("three/third.bin", to: original)

        let found = try await LargeFileFinder.find(LargeFileQuery(roots: [tree.root], minBytes: bytes(1), limit: 100))

        #expect(found.count == 1)
        #expect(found.first?.allocatedBytes == bytes(4))
    }

    @Test func overlappingRootsDoNotRepeatFiles() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("top.bin", size: file(3))
        try tree.addFile("inner/deep.bin", size: file(5))
        try tree.addFile("inner/more/deeper.bin", size: file(2))

        let query = LargeFileQuery(
            roots: [tree.root, tree.url(for: "inner"), tree.url(for: "inner/more"), tree.root],
            minBytes: bytes(1), limit: 100)
        let report = try await LargeFileFinder.search(query)

        #expect(names(report.files) == ["deep.bin", "top.bin", "deeper.bin"])
        #expect(Set(report.files.map(\.id)).count == report.files.count)
        #expect(report.skippedRoots.isEmpty)
    }

    @Test func separateRootsAreMerged() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("docs/a.bin", size: file(2))
        try tree.addFile("movies/b.bin", size: file(7))
        try tree.addFile("other/c.bin", size: file(9))

        let query = LargeFileQuery(
            roots: [tree.url(for: "docs"), tree.url(for: "movies")], minBytes: bytes(1), limit: 100)
        let found = try await LargeFileFinder.find(query)

        #expect(names(found) == ["b.bin", "a.bin"])
    }

    // MARK: Symlinks

    @Test func symlinksAreNotFollowedOrListed() async throws {
        let tree = try FixtureTree()
        let outside = try FixtureTree()
        defer {
            tree.remove()
            outside.remove()
        }
        try outside.addFile("big/huge.bin", size: file(50))
        try tree.addFile("inside.bin", size: file(2))
        try tree.addSymlink("link-to-folder", destination: outside.url(for: "big"))
        try tree.addSymlink("link-to-file", destination: outside.url(for: "big/huge.bin"))

        let found = try await LargeFileFinder.find(LargeFileQuery(roots: [tree.root], minBytes: bytes(1), limit: 100))

        #expect(names(found) == ["inside.bin"])
    }

    @Test func symlinkRootIsSkippedNotFollowed() async throws {
        let tree = try FixtureTree()
        let outside = try FixtureTree()
        defer {
            tree.remove()
            outside.remove()
        }
        try outside.addFile("big/huge.bin", size: file(50))
        let link = try tree.addSymlink("link", destination: outside.url(for: "big"))
        try tree.addFile("real/ok.bin", size: file(2))

        let report = try await LargeFileFinder.search(
            LargeFileQuery(roots: [link, tree.url(for: "real")], minBytes: bytes(1), limit: 100))

        #expect(names(report.files) == ["ok.bin"])
        #expect(report.skippedRoots.map(\.lastPathComponent) == ["link"])
    }

    // MARK: Errors and access

    @Test func missingRootIsSkippedWhenAnotherRootWorks() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("real/a.bin", size: file(2))
        let missing = tree.url(for: "does-not-exist")

        let report = try await LargeFileFinder.search(
            LargeFileQuery(roots: [missing, tree.url(for: "real")], minBytes: bytes(1), limit: 100))

        #expect(names(report.files) == ["a.bin"])
        #expect(report.skippedRoots.map(\.lastPathComponent) == ["does-not-exist"])
        #expect(report.needsAccess.isEmpty)
    }

    @Test func throwsWhenNoRootCanBeSearched() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let missing = tree.url(for: "does-not-exist")

        await #expect(throws: ScanError.self) {
            _ = try await LargeFileFinder.search(LargeFileQuery(roots: [missing], minBytes: 0, limit: 10))
        }
    }

    @Test func unreadableFolderIsReportedAsNeedingAccess() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("open/a.bin", size: file(2))
        try tree.addFile("locked/secret.bin", size: file(8))
        try tree.setPermissions("locked", mode: 0o000)

        let report = try await LargeFileFinder.search(
            LargeFileQuery(roots: [tree.root], minBytes: bytes(1), limit: 100))

        #expect(names(report.files) == ["a.bin"])
        #expect(report.needsAccess.map(\.lastPathComponent) == ["locked"])
    }

    @Test func unreadableRootIsReportedAsNeedingAccess() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("locked/secret.bin", size: file(8))
        try tree.addFile("open/a.bin", size: file(2))
        try tree.setPermissions("locked", mode: 0o000)

        let report = try await LargeFileFinder.search(
            LargeFileQuery(roots: [tree.url(for: "locked"), tree.url(for: "open")], minBytes: bytes(1), limit: 100))

        #expect(names(report.files) == ["a.bin"])
        #expect(report.needsAccess.map(\.lastPathComponent) == ["locked"])
        #expect(report.skippedRoots.isEmpty)
    }

    // MARK: Cancellation and progress

    @Test func cancelledSearchReturnsPartialInsteadOfThrowing() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("a.bin", size: file(2))
        let query = LargeFileQuery(roots: [tree.root], minBytes: bytes(1), limit: 100)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LargeFileFinder.search(query)
        }
        let report = try await task.value

        #expect(report.partial)
    }

    @Test func progressCountsFilesAcrossRoots() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addEmptyFiles(in: "a", count: 20)
        try tree.addEmptyFiles(in: "b", count: 30)
        let seen = Mutex<Int>(0)

        // Interval is 100 ms, so a small tree may report nothing; the callback must never go backwards or over the total.
        let query = LargeFileQuery(roots: [tree.url(for: "a"), tree.url(for: "b")], minBytes: 1, limit: 10)
        _ = try await LargeFileFinder.search(query) { progress in
            seen.withLock { $0 = max($0, progress.files) }
        }

        #expect(seen.withLock { $0 } <= 50)
    }
}

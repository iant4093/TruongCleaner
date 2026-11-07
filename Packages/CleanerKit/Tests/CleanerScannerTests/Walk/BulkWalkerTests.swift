import CleanerTestSupport
import Darwin
import Foundation
import Synchronization
import Testing
@testable import CleanerScanner

/// Runs file-system setup that takes a while (thousands of files) on a dispatch thread of its own.
/// Left on the cooperative pool it holds one of the few threads (three on a small CI runner) while
/// the timing tests in the same run wait for a free one.
private func offPool(_ setup: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        setupQueue.async {
            do {
                try setup()
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private let setupQueue = DispatchQueue(label: "TruongCleaner.TestSetup", qos: .userInitiated)

/// Walker tests. Every tree is a fixture under `build/test-fixtures/`; nothing reads the real home folder.
struct BulkWalkerTests {
    /// APFS allocates in 4 KB units, so sizes that are multiples of this have exact expected values.
    private static let page = 4096

    private func bytes(_ pages: Int) -> Int64 { Int64(pages * Self.page) }

    private func file(_ pages: Int) -> Int { pages * Self.page }

    private func node(_ result: WalkResult, _ tree: FixtureTree, _ relativePath: String) -> NodeTotal? {
        let path = tree.url(for: relativePath).path
        return result.nodes.first { $0.url.path == path }
    }

    private func options(workers: Int = 4, depth: Int = 8, top: Int = 0) -> WalkOptions {
        WalkOptions(maxWorkers: workers, totalsDepth: depth, topFilesCount: top)
    }

    // MARK: 1. Totals

    @Test(arguments: [1, 4])
    func totalsMatchAHandComputedTree(workers: Int) async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("a.bin", size: file(1))
        try tree.addFile("d1/b.bin", size: file(2))
        try tree.addFile("d1/d2/c.bin", size: file(3))
        try tree.addFile("d1/d2/d3/e.bin", size: file(5))
        try tree.addFile("d1/d2/d3/d4/f.bin", size: file(7))
        try tree.addFile("other/g.bin", size: file(11))

        let result = try await BulkWalker.walk(tree.root, options: options(workers: workers, depth: 3))

        #expect(result.partial == false)
        #expect(result.files == 6)
        #expect(result.directories == 6)  // root, d1, d2, d3, d4, other
        #expect(result.symlinks == 0)
        #expect(result.otherErrors == 0)
        #expect(result.deniedCount == 0)
        #expect(result.privateSizeMissing == 0)

        let root = try #require(result.nodes.first)
        #expect(root.depth == 0)
        #expect(root.kind == .directory)
        #expect(root.url.path == tree.root.path)
        #expect(root.allocatedBytes == bytes(1 + 2 + 3 + 5 + 7 + 11))
        #expect(root.fileCount == 6)

        #expect(try #require(node(result, tree, "d1")).allocatedBytes == bytes(2 + 3 + 5 + 7))
        #expect(try #require(node(result, tree, "d1/d2")).allocatedBytes == bytes(3 + 5 + 7))
        #expect(try #require(node(result, tree, "d1/d2/d3")).allocatedBytes == bytes(5 + 7))
        #expect(try #require(node(result, tree, "d1/d2/d3")).fileCount == 2)
        #expect(try #require(node(result, tree, "other")).allocatedBytes == bytes(11))
        #expect(try #require(node(result, tree, "a.bin")).kind == .file)
        #expect(try #require(node(result, tree, "a.bin")).allocatedBytes == bytes(1))
        #expect(try #require(node(result, tree, "d1/d2/c.bin")).depth == 3)

        // Depth 3 is the limit: entries below it are folded into d3 and have no node of their own.
        #expect(node(result, tree, "d1/d2/d3/e.bin") == nil)
        #expect(node(result, tree, "d1/d2/d3/d4") == nil)

        // Sorted by depth, root first.
        #expect(result.nodes.map(\.depth) == result.nodes.map(\.depth).sorted())
    }

    // MARK: 2. Hard links

    @Test(arguments: [1, 4])
    func hardLinksAreCountedOnce(workers: Int) async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let original = try tree.addFile("one/data.bin", size: file(3))
        try tree.addHardLink("one/again.bin", to: original)
        try tree.addHardLink("two/third.bin", to: original)
        try tree.addFile("two/plain.bin", size: file(2))

        let result = try await BulkWalker.walk(tree.root, options: options(workers: workers))

        let root = try #require(result.nodes.first)
        #expect(root.allocatedBytes == bytes(3 + 2))
        #expect(root.fileCount == 2)
        #expect(result.files == 2)
        #expect(result.hardLinkDuplicates == 2)
        // Which folder holds the shared file's bytes depends on which name a worker meets first.
        // Together the two folders count it exactly once.
        let one = try #require(node(result, tree, "one"))
        let two = try #require(node(result, tree, "two"))
        #expect(one.allocatedBytes + two.allocatedBytes == bytes(3 + 2))
        #expect(one.allocatedBytes == bytes(3) || two.allocatedBytes == bytes(3 + 2))
    }

    // MARK: 3. Symlinks

    @Test func symlinksAreNotFollowed() async throws {
        let tree = try FixtureTree()
        let outside = try FixtureTree()
        defer {
            tree.remove()
            outside.remove()
        }
        try outside.addFile("big/huge.bin", size: file(100))
        try tree.addFile("inside.bin", size: file(1))
        try tree.addSymlink("link-to-folder", destination: outside.url(for: "big"))
        try tree.addSymlink("link-to-file", destination: outside.url(for: "big/huge.bin"))
        try tree.addSymlink("link-to-self", destination: tree.root)

        let result = try await BulkWalker.walk(tree.root, options: options())

        let root = try #require(result.nodes.first)
        #expect(root.allocatedBytes == bytes(1))
        #expect(result.files == 1)
        #expect(result.symlinks == 3)
        #expect(result.directories == 1)
        #expect(result.otherErrors == 0)
        let link = try #require(node(result, tree, "link-to-folder"))
        #expect(link.kind == .symlink)
        #expect(link.allocatedBytes == 0)
    }

    // MARK: 4. Permission denied

    @Test func unreadableFolderIsReportedNotCountedAsEmpty() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("ok/fine.bin", size: file(2))
        try tree.addFile("locked/secret.bin", size: file(9))
        try tree.setPermissions("locked", mode: 0o000)
        let locked = tree.url(for: "locked")
        try #require(!FileManager.default.isReadableFile(atPath: locked.path), "tests must not run as root")

        let result = try await BulkWalker.walk(tree.root, options: options())

        #expect(result.deniedCount == 1)
        #expect(result.deniedDirectories.map(\.path) == [locked.path])
        let root = try #require(result.nodes.first)
        #expect(root.allocatedBytes == bytes(2))
        #expect(try #require(node(result, tree, "ok")).allocatedBytes == bytes(2))
        // The folder still has a node, so the caller can show it as "needs access" instead of 0 bytes.
        #expect(node(result, tree, "locked") != nil)
        #expect(result.otherErrors == 0)
    }

    // MARK: 5. Clones

    // Real numbers on APFS (one 4 MB file plus two clones): allocated 12,582,912 (3 x 4,194,304),
    // private 0, because every block is shared by all three files.
    @Test func cloneSharedBlocksAreNotPrivate() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let original = try tree.addFile("a.bin", size: 4 * 1024 * 1024)
        try tree.clone(original, to: "b.bin")
        try tree.clone(original, to: "sub/c.bin")

        let result = try await BulkWalker.walk(tree.root, options: options())

        let root = try #require(result.nodes.first)
        #expect(root.allocatedBytes == 3 * 4 * 1024 * 1024)
        #expect(root.privateBytes < root.allocatedBytes)
        #expect(result.privateSizeMissing == 0)
        // Every file shares all blocks with the others, so none of them frees space on its own.
        for name in ["a.bin", "b.bin", "sub/c.bin"] {
            let item = try #require(node(result, tree, name))
            #expect(item.privateBytes < item.allocatedBytes, "\(name)")
        }
    }

    @Test func privateEqualsAllocatedForPlainFiles() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("a/plain.bin", size: file(6))

        let result = try await BulkWalker.walk(tree.root, options: options())

        let root = try #require(result.nodes.first)
        #expect(root.allocatedBytes == bytes(6))
        #expect(root.privateBytes == root.allocatedBytes)
    }

    // MARK: 6. Newest modification

    @Test func newestModificationIsTheNewestEntryInside() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let middle = Date(timeIntervalSince1970: 1_650_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_000_123)
        let sub = Date(timeIntervalSince1970: 1_500_000_000)
        try tree.addFile("d/old.bin", size: file(1), modified: old)
        try tree.addFile("d/inner/middle.bin", size: file(1), modified: middle)
        try tree.addFile("d/inner/deep/newest.bin", size: file(1), modified: newest)
        try tree.addFile("e/only.bin", size: file(1), modified: old)
        // Folder dates change when children are added, so set them last. They also count, so keep them old.
        for folder in ["d/inner/deep", "d/inner", "d", "e"] {
            try tree.setModified(folder, to: sub)
        }

        let result = try await BulkWalker.walk(tree.root, options: options())

        #expect(try #require(node(result, tree, "d")).newestModification == newest)
        #expect(try #require(node(result, tree, "d/inner")).newestModification == newest)
        #expect(try #require(node(result, tree, "d/inner/deep")).newestModification == newest)
        #expect(try #require(node(result, tree, "d/inner/middle.bin")).newestModification == middle)
        #expect(try #require(node(result, tree, "e")).newestModification == old)
        // The root's own date is "now", but it can never be older than anything inside.
        let rootDate = try #require(result.nodes.first?.newestModification)
        #expect(rootDate >= newest)
    }

    @Test func newestModificationSeesFoldersBelowTheKeptDepth() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let deepFile = Date(timeIntervalSince1970: 1_650_000_000)
        let newestFolder = Date(timeIntervalSince1970: 1_700_000_000)
        try tree.addFile("d/x/y/z/file.bin", size: file(1), modified: deepFile)
        try tree.setModified("d/x/y/z", to: old)
        try tree.setModified("d/x/y", to: newestFolder)
        try tree.setModified("d/x", to: old)
        try tree.setModified("d", to: old)

        // Depth 1 keeps only d; everything below is folded into it.
        let result = try await BulkWalker.walk(tree.root, options: options(depth: 1))

        #expect(try #require(node(result, tree, "d")).newestModification == newestFolder)
        #expect(node(result, tree, "d/x") == nil)
    }

    // MARK: 7. Depth and top files

    @Test func totalsDepthOneKeepsRootAndDirectChildrenOnly() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("top.bin", size: file(1))
        try tree.addFile("a/in-a.bin", size: file(2))
        try tree.addFile("a/b/in-b.bin", size: file(3))
        try tree.addFile("c/in-c.bin", size: file(4))

        let result = try await BulkWalker.walk(tree.root, options: options(depth: 1))

        let names = Set(result.nodes.map { $0.url.lastPathComponent })
        #expect(names == [tree.root.lastPathComponent, "top.bin", "a", "c"])
        #expect(result.nodes.map(\.depth).sorted() == [0, 1, 1, 1])
        #expect(try #require(node(result, tree, "a")).allocatedBytes == bytes(2 + 3))
        #expect(try #require(node(result, tree, "c")).allocatedBytes == bytes(4))
        #expect(try #require(result.nodes.first).allocatedBytes == bytes(1 + 2 + 3 + 4))
        #expect(result.topFiles.isEmpty)
    }

    @Test func totalsDepthZeroKeepsOnlyTheRoot() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("a/in-a.bin", size: file(2))

        let result = try await BulkWalker.walk(tree.root, options: options(depth: 0))

        #expect(result.nodes.count == 1)
        #expect(result.nodes.first?.allocatedBytes == bytes(2))
    }

    @Test(arguments: [1, 4])
    func topFilesReturnsTheLargestAtAnyDepth(workers: Int) async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("s1.bin", size: file(1))
        try tree.addFile("a/s2.bin", size: file(2))
        try tree.addFile("a/b/c/big20.bin", size: file(20))
        try tree.addFile("a/b/mid9.bin", size: file(9))
        try tree.addFile("z/huge40.bin", size: file(40))
        try tree.addFile("z/s3.bin", size: file(3))

        let result = try await BulkWalker.walk(tree.root, options: options(workers: workers, depth: 1, top: 3))

        #expect(result.topFiles.map(\.allocatedBytes) == [bytes(40), bytes(20), bytes(9)])
        #expect(result.topFiles.map { $0.url.lastPathComponent } == ["huge40.bin", "big20.bin", "mid9.bin"])
        #expect(result.topFiles.map(\.depth) == [2, 4, 3])
        #expect(result.topFiles.allSatisfy { $0.kind == .file && $0.fileCount == 1 })
        #expect(result.topFiles.first?.url.path == tree.url(for: "z/huge40.bin").path)
    }

    // MARK: 8. Cancellation

    @Test func cancellationReturnsAPartialResultQuickly() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try await offPool {
            for folder in 0..<200 {
                try tree.addEmptyFiles(in: "d\(folder)", count: 100)
            }
        }

        // The first progress callback holds the single worker until the test has cancelled the task,
        // so the walk is guaranteed to be unfinished when the cancel arrives.
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let first = Mutex(true)
        let walk = Task {
            try await BulkWalker.walk(tree.root, options: WalkOptions(maxWorkers: 1, totalsDepth: 1)) { _ in
                if first.withLock({ value in defer { value = false }; return value }) {
                    startedSignal.yield()
                    _ = release.wait(timeout: .now() + 10)
                }
            }
        }
        for await _ in started { break }
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        walk.cancel()
        release.signal()
        let result = try await walk.value
        let elapsed = clock.now - cancelledAt

        #expect(result.partial)
        #expect(result.files < 20_000)
        #expect(elapsed < timingBudget(.milliseconds(500)))
    }

    @Test func timeLimitReturnsAPartialResult() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        for folder in 0..<20 {
            try tree.addFile("d\(folder)/f.bin", size: file(1))
        }

        let result = try await BulkWalker.walk(
            tree.root, options: WalkOptions(maxWorkers: 2, totalsDepth: 1, limit: .zero))

        #expect(result.partial)
        #expect(result.files < 20)
    }

    @Test func aCompleteWalkIsNotPartial() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("a/b.bin", size: file(1))

        let result = try await BulkWalker.walk(tree.root, options: options(depth: 1))

        #expect(result.partial == false)
    }

    // MARK: 9. Bad roots

    @Test func symlinkRootThrows() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("real/a.bin", size: file(1))
        let link = try tree.addSymlink("link", destination: tree.url(for: "real"))

        await #expect(throws: ScanError.notADirectory(link)) {
            _ = try await BulkWalker.walk(link, options: WalkOptions())
        }
    }

    @Test func fileRootThrows() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let plain = try tree.addFile("a.bin", size: file(1))

        await #expect(throws: ScanError.notADirectory(plain)) {
            _ = try await BulkWalker.walk(plain, options: WalkOptions())
        }
    }

    @Test func missingRootThrows() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let missing = tree.url(for: "nothing-here")

        await #expect(throws: ScanError.cannotOpen(missing, errno: ENOENT)) {
            _ = try await BulkWalker.walk(missing, options: WalkOptions())
        }
    }

    // MARK: 10. Odd entries

    @Test func emptyFolderFifoAndZeroByteFileAreHandled() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addDirectory("empty")
        try tree.addFIFO("pipe")
        try tree.addFile("zero.bin", size: 0)

        let result = try await BulkWalker.walk(tree.root, options: options())

        #expect(result.directories == 2)  // root and "empty"
        #expect(result.files == 2)  // the FIFO and the zero-byte file; neither is a folder or symlink
        #expect(result.otherErrors == 0)
        #expect(result.privateSizeMissing == 0)
        let root = try #require(result.nodes.first)
        #expect(root.allocatedBytes == 0)
        #expect(root.privateBytes == 0)
        #expect(try #require(node(result, tree, "pipe")).kind == .other)
        #expect(try #require(node(result, tree, "zero.bin")).kind == .file)
        #expect(try #require(node(result, tree, "empty")).fileCount == 0)
    }

    @Test func emptyRootGivesJustTheRoot() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }

        let result = try await BulkWalker.walk(tree.root, options: options())

        #expect(result.nodes.count == 1)
        #expect(result.directories == 1)
        #expect(result.files == 0)
        #expect(result.partial == false)
    }

    // MARK: Extra checks

    @Test func fileFlagsAreReported() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("hidden.bin", size: file(1))
        try tree.addFile("normal.bin", size: file(1))
        try tree.setFlags("hidden.bin", flags: UInt32(UF_HIDDEN))

        let result = try await BulkWalker.walk(tree.root, options: options())

        #expect(try #require(node(result, tree, "hidden.bin")).flags & UInt32(UF_HIDDEN) != 0)
        #expect(try #require(node(result, tree, "normal.bin")).flags & UInt32(UF_HIDDEN) == 0)
    }

    @Test func entryIDsMatchTheFileSystem() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let url = try tree.addFile("a/b.bin", size: file(1))
        var info = stat()
        try #require(lstat(url.path, &info) == 0)

        let result = try await BulkWalker.walk(tree.root, options: options())

        let item = try #require(node(result, tree, "a/b.bin"))
        #expect(item.id.fileID == UInt64(info.st_ino))
        // Every entry in one volume carries the same fsid as the root.
        #expect(Set(result.nodes.map(\.id.fsid)).count == 1)
    }

    @Test func progressIsThrottledAndNeverOverlaps() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        for folder in 0..<50 {
            try tree.addFile("d\(folder)/f.bin", size: file(1))
        }
        let calls = Mutex(0)
        let overlapped = Mutex(false)
        let running = Mutex(false)

        _ = try await BulkWalker.walk(
            tree.root, options: WalkOptions(maxWorkers: 4, totalsDepth: 1, progressInterval: .seconds(10))
        ) { _ in
            if running.withLock({ value in defer { value = true }; return value }) {
                overlapped.withLock { $0 = true }
            }
            calls.withLock { $0 += 1 }
            running.withLock { $0 = false }
        }

        // A 10 second interval allows only the first snapshot in this short walk.
        #expect(calls.withLock { $0 } == 1)
        #expect(overlapped.withLock { $0 } == false)
    }
}

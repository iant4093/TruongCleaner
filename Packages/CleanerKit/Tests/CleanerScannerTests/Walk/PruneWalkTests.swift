import CleanerTestSupport
import Foundation
import Testing
@testable import CleanerScanner

/// `WalkOptions.pruneNames`: a pruned folder is one node, and its subtree is still counted in full.
struct PruneWalkTests {
    private static let page = 4096

    private func bytes(_ pages: Int) -> Int64 { Int64(pages * Self.page) }

    private func node(_ result: WalkResult, _ tree: FixtureTree, _ relativePath: String) -> NodeTotal? {
        let path = tree.url(for: relativePath).path.precomposedStringWithCanonicalMapping
        return result.nodes.first { $0.url.path.precomposedStringWithCanonicalMapping == path }
    }

    /// A project with one artifact folder, a second artifact written in another case, and plain folders.
    private func buildProject(_ tree: FixtureTree) throws {
        try tree.addFile("proj/src/main.swift", size: Self.page)
        try tree.addFile("proj/node_modules/a/index.js", size: 2 * Self.page)
        try tree.addFile("proj/node_modules/a/lib/deep.js", size: 3 * Self.page)
        try tree.addFile("proj/node_modules/b/x.js", size: Self.page)
        try tree.addFile("proj/node_modules/top.js", size: Self.page)
        try tree.addFile("proj/node_modules/a/node_modules/inner/z.js", size: Self.page)
        try tree.addFile("other/Node_Modules/c/y.js", size: 4 * Self.page)
    }

    private func walk(
        _ tree: FixtureTree, workers: Int = 4, depth: Int = 8,
        prune: Set<String> = [], keep: Set<String> = []
    ) async throws -> WalkResult {
        try await BulkWalker.walk(
            tree.root,
            options: WalkOptions(
                maxWorkers: workers, totalsDepth: depth, pruneNames: prune, pruneKeepNames: keep))
    }

    @Test(arguments: [1, 4])
    func aPrunedFolderIsOneNodeWithTheWholeSubtreeInIt(workers: Int) async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try buildProject(tree)

        let result = try await walk(tree, workers: workers, prune: ["node_modules"])

        let modules = try #require(node(result, tree, "proj/node_modules"))
        #expect(modules.kind == .directory)
        #expect(modules.allocatedBytes == bytes(2 + 3 + 1 + 1 + 1))
        #expect(modules.fileCount == 5 + 0)
        // Matching ignores ASCII case.
        let other = try #require(node(result, tree, "other/Node_Modules"))
        #expect(other.allocatedBytes == bytes(4))

        // Nothing is kept below a pruned folder, at any depth.
        let below = result.nodes.filter {
            $0.url.path.hasPrefix(tree.url(for: "proj/node_modules").path + "/")
                || $0.url.path.hasPrefix(tree.url(for: "other/Node_Modules").path + "/")
        }
        #expect(below.isEmpty)
        // Everything outside is kept as before.
        #expect(node(result, tree, "proj/src/main.swift") != nil)
        #expect(node(result, tree, "proj/src") != nil)
    }

    @Test(arguments: [1, 4])
    func totalsAreTheSameWithAndWithoutPrune(workers: Int) async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try buildProject(tree)

        let plain = try await walk(tree, workers: workers)
        let pruned = try await walk(tree, workers: workers, prune: ["node_modules"])

        #expect(pruned.nodes.count < plain.nodes.count)
        #expect(pruned.files == plain.files)
        #expect(pruned.directories == plain.directories)
        #expect(pruned.symlinks == plain.symlinks)
        #expect(pruned.otherErrors == 0)
        #expect(pruned.partial == false)
        for path in [nil, "proj", "proj/node_modules", "proj/src", "other", "other/Node_Modules"] {
            let before = try #require(path.map { node(plain, tree, $0) } ?? plain.nodes.first, "\(path ?? "root")")
            let after = try #require(path.map { node(pruned, tree, $0) } ?? pruned.nodes.first, "\(path ?? "root")")
            #expect(after.allocatedBytes == before.allocatedBytes, "\(path ?? "root")")
            #expect(after.privateBytes == before.privateBytes, "\(path ?? "root")")
            #expect(after.fileCount == before.fileCount, "\(path ?? "root")")
            #expect(after.newestModification == before.newestModification, "\(path ?? "root")")
        }
    }

    @Test
    func withoutPruneNamesEveryNodeIsKept() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try buildProject(tree)

        let result = try await walk(tree)

        #expect(node(result, tree, "proj/node_modules/a/lib/deep.js") != nil)
        #expect(node(result, tree, "proj/node_modules/a/node_modules/inner") != nil)
    }

    @Test(arguments: [1, 4])
    func keepNamesGetANodeOnlyDirectlyInsideAPrunedFolder(workers: Int) async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("proj/node_modules/.git/HEAD", size: Self.page)
        try tree.addFile("proj/node_modules/pkg/.git/HEAD", size: Self.page)
        try tree.addFile("proj/node_modules/pkg/index.js", size: Self.page)
        try tree.addFile("proj/build/.GIT/HEAD", size: Self.page)

        let result = try await walk(tree, workers: workers, prune: ["node_modules", "build"], keep: [".git"])

        let git = try #require(node(result, tree, "proj/node_modules/.git"))
        #expect(git.allocatedBytes == bytes(1))
        // Its own contents are not kept, and a deeper `.git` is not a child of the pruned folder.
        #expect(node(result, tree, "proj/node_modules/.git/HEAD") == nil)
        #expect(node(result, tree, "proj/node_modules/pkg") == nil)
        #expect(node(result, tree, "proj/node_modules/pkg/.git") == nil)
        // Case does not matter for the keep names either.
        #expect(node(result, tree, "proj/build/.GIT") != nil)
        let modules = try #require(node(result, tree, "proj/node_modules"))
        #expect(modules.allocatedBytes == bytes(3))
    }

    @Test
    func anEntryWithANonASCIINameInsideAPrunedFolderIsAlwaysKept() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("proj/node_modules/caf\u{E9}/a.js", size: Self.page)
        try tree.addFile("proj/node_modules/plain/a.js", size: Self.page)
        try tree.addFile("proj/node_modules/\u{E9}.js", size: Self.page)

        let result = try await walk(tree, prune: ["node_modules"], keep: [".git"])

        #expect(node(result, tree, "proj/node_modules/caf\u{E9}") != nil)
        #expect(node(result, tree, "proj/node_modules/\u{E9}.js") != nil)
        #expect(node(result, tree, "proj/node_modules/plain") == nil)
        #expect(try #require(node(result, tree, "proj/node_modules")).allocatedBytes == bytes(3))
    }

    @Test
    func aPrunedNameWithNonASCIICharactersPrunesNothing() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("proj/caf\u{E9}/a/b.js", size: Self.page)

        let result = try await walk(tree, prune: ["caf\u{E9}"])

        #expect(node(result, tree, "proj/caf\u{E9}/a") != nil)
    }

    @Test
    func pruningDoesNotAddNodesBeyondTheTotalsDepth() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("proj/node_modules/.git/HEAD", size: Self.page)
        try tree.addFile("proj/node_modules/a.js", size: Self.page)

        // Depth 2 reaches node_modules but not its children.
        let result = try await walk(tree, depth: 2, prune: ["node_modules"], keep: [".git"])

        #expect(node(result, tree, "proj/node_modules") != nil)
        #expect(node(result, tree, "proj/node_modules/.git") == nil)
        #expect(node(result, tree, "proj/node_modules/a.js") == nil)
        // A pruned folder deeper than the totals depth is folded into its ancestor as before.
        let shallow = try await walk(tree, depth: 1, prune: ["node_modules"])
        #expect(node(shallow, tree, "proj/node_modules") == nil)
        #expect(try #require(node(shallow, tree, "proj")).allocatedBytes == bytes(2))
    }

    @Test
    func manyFilesInsideAPrunedFolderAddNoNodes() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("proj/package.json", size: Self.page)
        for package in 0..<20 {
            try tree.addEmptyFiles(in: "proj/node_modules/pkg\(package)/lib", count: 100)
        }

        let pruned = try await walk(tree, prune: ["node_modules"])
        let plain = try await walk(tree)

        #expect(pruned.files == 2_001)
        #expect(pruned.files == plain.files)
        // root, proj, package.json, node_modules.
        #expect(pruned.nodes.count == 4)
        #expect(plain.nodes.count > 2_000)
    }
}

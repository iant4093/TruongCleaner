import CleanerTestSupport
import Foundation
import Testing
@testable import CleanerScanner

struct FixtureTreeTests {
    @Test func buildsAndRemovesATree() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }

        // The tree lives under the repo's build/test-fixtures (or TC_FIXTURE_ROOT).
        #expect(tree.root.path.contains("test-fixtures") || ProcessInfo.processInfo.environment["TC_FIXTURE_ROOT"] != nil)
        #expect(FileManager.default.fileExists(atPath: tree.root.path))

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let file = try tree.addFile("a/b/data.bin", size: 4096, modified: date)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.size] as? Int) == 4096)
        #expect((attributes[.modificationDate] as? Date) == date)

        try tree.addDirectory("empty")
        let link = try tree.addSymlink("link", destination: file)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == file.path)

        let hard = try tree.addHardLink("a/hard.bin", to: file)
        #expect((try FileManager.default.attributesOfItem(atPath: hard.path)[.referenceCount] as? Int) == 2)

        try tree.setPermissions("a", mode: 0o000)
        #expect(!FileManager.default.isReadableFile(atPath: tree.url(for: "a").path))

        tree.remove()
        #expect(!FileManager.default.fileExists(atPath: tree.root.path))
    }

    @Test func containsOnlyPathsInsideTheRoot() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }

        #expect(tree.contains(tree.root.appending(path: "x/y")))
        #expect(!tree.contains(tree.root))
        #expect(!tree.contains(tree.root.appending(path: "../other")))
        #expect(!tree.contains(tree.root.deletingLastPathComponent()))
    }

    @Test func scanEnginePlaceholderExists() {
        _ = ScanEngine()
    }
}

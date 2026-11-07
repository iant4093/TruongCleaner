import CleanerTestSupport
import Foundation
import Testing

@testable import CleanerScanner

/// REQ-PERM-01: the Full Disk Access verdict, on fixture folders only.
struct AccessProbeTests {
    @Test func readableFolderMeansGranted() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("open/item.txt", size: 1)

        let state = await AccessProbe.fullDiskAccess(probing: [tree.url(for: "open")])
        #expect(state == .granted)
    }

    @Test func emptyReadableFolderMeansGranted() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addDirectory("empty")

        #expect(AccessProbe.state(probing: [tree.url(for: "empty")]) == .granted)
    }

    @Test func oneReadableFolderBeatsDeniedOnes() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("locked/item.txt", size: 1)
        try tree.addFile("open/item.txt", size: 1)
        try tree.setPermissions("locked", mode: 0o000)

        let paths = [tree.url(for: "locked"), tree.url(for: "open")]
        #expect(AccessProbe.state(probing: paths) == .granted)
    }

    @Test func everyExistingFolderDeniedMeansNotGranted() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("a/item.txt", size: 1)
        try tree.addFile("b/item.txt", size: 1)
        try tree.setPermissions("a", mode: 0o000)
        try tree.setPermissions("b", mode: 0o000)

        let paths = [tree.url(for: "a"), tree.url(for: "b")]
        #expect(AccessProbe.state(probing: paths) == .notGranted)
    }

    @Test func missingFoldersAreIgnoredWhenOthersAreDenied() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("locked/item.txt", size: 1)
        try tree.setPermissions("locked", mode: 0o000)

        let paths = [tree.url(for: "gone"), tree.url(for: "locked"), tree.url(for: "also-gone")]
        #expect(AccessProbe.state(probing: paths) == .notGranted)
    }

    @Test func nothingExistingMeansUnknown() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }

        #expect(AccessProbe.state(probing: [tree.url(for: "gone"), tree.url(for: "gone2")]) == .unknown)
        #expect(AccessProbe.state(probing: []) == .unknown)
    }

    @Test func otherFailureMeansUnknown() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        try tree.addFile("plain-file", size: 1)  // opendir on a file fails with ENOTDIR
        try tree.addFile("locked/item.txt", size: 1)
        try tree.setPermissions("locked", mode: 0o000)

        #expect(AccessProbe.state(probing: [tree.url(for: "plain-file")]) == .unknown)
        // One refusal plus one unexplained failure is not a clear "not granted".
        let paths = [tree.url(for: "locked"), tree.url(for: "plain-file")]
        #expect(AccessProbe.state(probing: paths) == .unknown)
    }

    @Test func defaultPathsAreTheFourProtectedFolders() throws {
        let tree = try FixtureTree()
        defer { tree.remove() }

        let paths = AccessProbe.defaultPaths(home: tree.root)
        let homeCount = tree.root.pathComponents.count
        #expect(paths.count == 4)
        #expect(paths.allSatisfy { $0.pathComponents.starts(with: tree.root.pathComponents) })
        #expect(paths.map { $0.pathComponents.dropFirst(homeCount).joined(separator: "/") } == [
            "Library/Safari",
            "Library/Mail",
            "Library/Messages",
            "Library/Containers/com.apple.stocks",
        ])
    }

    @Test func fixtureHomeWithoutProtectedFoldersIsUnknownAndFast() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }

        let clock = ContinuousClock()
        let start = clock.now
        let state = await AccessProbe.fullDiskAccess(home: tree.root)
        let elapsed = start.duration(to: clock.now)
        #expect(state == .unknown)
        #expect(elapsed < .milliseconds(50))
    }
}

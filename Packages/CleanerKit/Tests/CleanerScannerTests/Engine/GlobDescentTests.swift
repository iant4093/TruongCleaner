import CleanerCore
import Foundation
import Testing
@testable import CleanerScanner

/// Which folders a `.glob` walk opens, and what that leaves out of the answer (nothing).
struct GlobDescentTests {
    private func filter(_ glob: String) throws -> DescentFilter {
        let rule = makeRule("t.glob", roots: [["x"]], match: .glob(glob))
        return try #require(DescentFilter(rule: rule))
    }

    private func enter(
        _ filter: DescentFilter, _ name: String, from cursor: DescentCursor, depth: Int
    ) -> DescentCursor? {
        name.withCString { filter.enter($0, from: cursor, depth: depth) }
    }

    // MARK: Decisions

    @Test
    func aLiteralWithAWildcardOpensOnlyTheFoldersThatMatchIt() throws {
        let filter = try filter("Install macOS*.app")
        let root = filter.rootCursor

        let match = try #require(enter(filter, "Install macOS Sequoia.app", from: root, depth: 0))
        #expect(match.free)
        #expect(enter(filter, "install macos sonoma.APP", from: root, depth: 0)?.free == true)
        #expect(enter(filter, "Safari.app", from: root, depth: 0) == nil)
        #expect(enter(filter, "Utilities", from: root, depth: 0) == nil)
    }

    @Test
    func everythingBelowAMatchIsOpened() throws {
        let filter = try filter("Install macOS*.app")
        let match = try #require(enter(filter, "Install macOS A.app", from: filter.rootCursor, depth: 0))

        #expect(enter(filter, "Contents", from: match, depth: 1)?.free == true)
    }

    @Test
    func aMultiLevelGlobOpensTheFoldersOnTheWayAndNotTheLastLevelThatMisses() throws {
        let filter = try filter("*/*.xcarchive")
        let dated = try #require(enter(filter, "2024-05-01", from: filter.rootCursor, depth: 0))

        #expect(dated.free == false)
        #expect(enter(filter, "App.xcarchive", from: dated, depth: 1)?.free == true)
        #expect(enter(filter, "Notes", from: dated, depth: 1) == nil)
    }

    @Test
    func aLiteralFirstComponentFiltersTheRootsChildren() throws {
        let filter = try filter("Logs/**/*.log")
        let logs = try #require(enter(filter, "logs", from: filter.rootCursor, depth: 0))

        #expect(enter(filter, "Cache", from: filter.rootCursor, depth: 0) == nil)
        // After `**` any folder may hold a match.
        #expect(enter(filter, "anything", from: logs, depth: 1)?.free == true)
    }

    @Test
    func braceAlternativesAreEachTried() throws {
        let filter = try filter("{Alpha,Beta/Gamma}/x")
        let beta = try #require(enter(filter, "beta", from: filter.rootCursor, depth: 0))

        #expect(enter(filter, "alpha", from: filter.rootCursor, depth: 0) != nil)
        #expect(enter(filter, "Delta", from: filter.rootCursor, depth: 0) == nil)
        #expect(enter(filter, "Gamma", from: beta, depth: 1) != nil)
        #expect(enter(filter, "Other", from: beta, depth: 1) == nil)
    }

    @Test
    func aNameThatIsNotUTF8IsOpened() throws {
        let filter = try filter("Install macOS*.app")
        let bytes: [CChar] = [CChar(bitPattern: 0xFF), CChar(bitPattern: 0xFE), 0]

        let cursor = bytes.withUnsafeBufferPointer { filter.enter($0.baseAddress!, from: filter.rootCursor, depth: 0) }

        #expect(cursor?.free == true)
    }

    @Test(arguments: [
        "**/node_modules",
        "**",
        "{**/a,b}",
    ])
    func patternsThatStartWithAnyDepthAreNotFiltered(glob: String) {
        let rule = makeRule("t.glob", roots: [["x"]], match: .glob(glob))
        #expect(DescentFilter(rule: rule) == nil)
    }

    @Test
    func onlyGlobRulesGetAFilter() {
        #expect(DescentFilter(rule: makeRule("t.children", roots: [["x"]])) == nil)
        #expect(DescentFilter(rule: makeRule("t.files", roots: [["x"]], match: .files(extensions: ["a"]))) == nil)
        #expect(DescentFilter(rule: makeRule("t.info", tier: .info, roots: [["x"]], match: .glob("a*"))) == nil)
    }

    // MARK: Walks

    @Test
    func theWalkReadsTheMatchInFullAndLeavesTheRestUnopened() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Apps/Install macOS A.app/Contents/Resources/payload.bin", pages: 3)
        try fixture.file("Apps/Install macOS A.app/Contents/Info.plist", pages: 1)
        for index in 0..<5 {
            try fixture.file("Apps/Other.app/Contents/Frameworks/f\(index)/lib.dylib", pages: 2)
        }
        try fixture.file("Apps/loose.txt", pages: 1)
        let rule = makeRule("t.install", roots: [["Apps"]], match: .glob("Install macOS*.app"))
        var options = WalkOptions(maxWorkers: 2, totalsDepth: 1)

        let everything = try await BulkWalker.walk(fixture.url("Apps"), options: options)
        options.descent = DescentFilter(rule: rule)
        let filtered = try await BulkWalker.walk(fixture.url("Apps"), options: options)

        let installer = try #require(filtered.nodes.first { $0.url.lastPathComponent == "Install macOS A.app" })
        let full = try #require(everything.nodes.first { $0.url.lastPathComponent == "Install macOS A.app" })
        #expect(installer.allocatedBytes == full.allocatedBytes)
        #expect(installer.allocatedBytes == fixture.bytes(4))
        #expect(installer.privateBytes == full.privateBytes)
        #expect(installer.fileCount == 2)
        #expect(filtered.nodes.contains { $0.url.lastPathComponent == "Other.app" } == false)
        // 2 files of the installer and the loose file; none of the other app's 5 files.
        #expect(filtered.files == 3)
        #expect(everything.files == 8)
        #expect(filtered.partial == false)
    }

    @Test
    func theEngineOffersTheSameInstallerWithAndWithoutTheFilter() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        func oldTree(_ path: String, pages: Int) throws {
            try fixture.file(path, pages: pages, modified: fixture.days(60))
        }
        try oldTree("Apps/Install macOS A.app/Contents/payload.bin", pages: 5)
        try oldTree("Apps/Install macOS B.app/Contents/payload.bin", pages: 2)
        try oldTree("Apps/Other.app/Contents/big.bin", pages: 9)
        for name in [
            "Install macOS A.app", "Install macOS B.app", "Install macOS A.app/Contents", "Install macOS B.app/Contents",
        ] {
            try fixture.tree.setModified("home/Apps/" + name, to: fixture.days(60))
        }
        let rule = makeRule(
            "t.install", roots: [["Apps"]], match: .glob("Install macOS*.app"), guards: Guards(minAge: .seconds(14 * 86_400)))
        let request = ScanRequest(rules: [rule], environment: fixture.environment)

        let plain = await ScanRun.execute(request, tuning: .reference) { _ in }
        let fast = await ScanRun.execute(request, tuning: .standard) { _ in }

        let before = try #require(plain.results.first)
        let after = try #require(fast.results.first)
        #expect(after.findings.map(\.name) == ["Install macOS A.app", "Install macOS B.app"])
        #expect(after.findings.map(\.allocatedBytes) == before.findings.map(\.allocatedBytes))
        #expect(after.findings.map(\.fileID) == before.findings.map(\.fileID))
        #expect(after.measuredBytes == before.measuredBytes)
        #expect(after.skippedCounts == before.skippedCounts)
    }
}

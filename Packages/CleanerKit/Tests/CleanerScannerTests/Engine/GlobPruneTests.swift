import CleanerCore
import Foundation
import Testing
@testable import CleanerScanner

/// Which folder names the engine lets the walker total as one node, and the project scan with pruning on.
struct GlobPruneTests {
    @Test
    func projectArtifactGlobGivesTheArtifactNames() throws {
        let rule = try #require(Catalog.all.first { $0.id == "dev.projectArtifacts" })

        let prune = GlobPrune(rule: rule)

        // `.next/cache` is two levels, so it is not named: a folder called `cache` elsewhere stays unpruned.
        #expect(prune.names == [
            "node_modules", ".build", "deriveddata", "target", "build", ".venv", "__pycache__", "pods",
            ".gradle", ".dart_tool",
        ])
        #expect(prune.keepNames == [".git"])
    }

    @Test(arguments: [
        "*/*.xcarchive",
        "Install macOS*.app",
        "*.{download,crdownload,part}",
        "*/**/*.log",
        "*/**/.next/cache",
        "node_modules",
        "**",
        "*/**/{a",
    ])
    func otherGlobShapesGiveNoNames(glob: String) {
        #expect(GlobPrune.names(forGlob: glob).isEmpty)
    }

    @Test
    func onlyAlternativesThatEndInAnyDepthThenANameCount() {
        #expect(GlobPrune.names(forGlob: "*/**/{Alpha,sub/Beta,**/Gamma}") == ["alpha", "gamma"])
        #expect(GlobPrune.names(forGlob: "a/**/Pods") == ["pods"])
    }

    @Test
    func nonGlobRulesAndInfoRulesAreNeverPruned() {
        let children = makeRule("t.children", roots: [["a"]])
        let info = makeRule("t.info", tier: .info, roots: [["a"]], match: .glob("*/**/node_modules"))
        #expect(GlobPrune(rule: children) == GlobPrune(rule: info))
        #expect(GlobPrune(rule: info).names.isEmpty)
    }

    @Test
    func keepNamesAreOnlySetWhenThereIsSomethingToPrune() {
        let plain = makeRule(
            "t.glob", roots: [["a"]], match: .glob("*.zip"), guards: Guards(skipIfContains: [".git"]))
        #expect(GlobPrune(rule: plain).keepNames.isEmpty)
    }

    // MARK: - Engine scan with pruning

    private let old = 60.0

    private func oldTree(_ fixture: EngineFixture, _ path: String, pages: Int = 1) throws {
        try fixture.file(path, pages: pages, modified: fixture.days(old))
        var parts = path.split(separator: "/").map(String.init)
        parts.removeLast()
        while !parts.isEmpty {
            try fixture.tree.setModified("home/" + parts.joined(separator: "/"), to: fixture.days(old))
            parts.removeLast()
        }
    }

    private func scan(_ fixture: EngineFixture) async throws -> RuleResult {
        let rule = try #require(Catalog.all.first { $0.id == "dev.projectArtifacts" })
        let environment = Environment(
            home: fixture.home, now: fixture.environment.now, projectFolders: [fixture.url("Code")])
        var report: ScanReport?
        for await event in await ScanEngine().scan(ScanRequest(rules: [rule], environment: environment)) {
            if case .finished(let final) = event { report = final }
        }
        return try #require(report?.results.first)
    }

    @Test
    func anArtifactIsOfferedWithItsFullSizeAndFileCount() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try oldTree(fixture, "Code/app/node_modules/a/index.js", pages: 2)
        try oldTree(fixture, "Code/app/node_modules/a/lib/deep/x.js", pages: 3)
        try oldTree(fixture, "Code/app/node_modules/b/y.js", pages: 1)
        try oldTree(fixture, "Code/app/node_modules/b/node_modules/c/z.js", pages: 1)
        try oldTree(fixture, "Code/app/src/main.js", pages: 1)

        let result = try await scan(fixture)

        let item = try #require(result.findings.first)
        #expect(result.findings.count == 1)
        #expect(item.url.plainPath == fixture.url("Code/app/node_modules").plainPath)
        #expect(item.allocatedBytes == fixture.bytes(2 + 3 + 1 + 1))
        #expect(item.itemCount == 4)
        #expect(result.partial == false)
    }

    @Test
    func aGitFolderDirectlyInsideAnArtifactStillKeepsIt() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try oldTree(fixture, "Code/keep/node_modules/.git/HEAD")
        try oldTree(fixture, "Code/keep/node_modules/pkg/index.js")
        try oldTree(fixture, "Code/deep/node_modules/pkg/.git/HEAD")
        try oldTree(fixture, "Code/deep/node_modules/pkg/index.js")
        try oldTree(fixture, "Code/shout/node_modules/.GIT/HEAD")

        let result = try await scan(fixture)

        // Only a `.git` directly inside counts, as before; case does not matter.
        #expect(result.findings.map { $0.url.pathComponents.suffix(2).joined(separator: "/") } == ["deep/node_modules"])
        #expect(result.skippedCounts[.excludedName] == 2)
    }
}

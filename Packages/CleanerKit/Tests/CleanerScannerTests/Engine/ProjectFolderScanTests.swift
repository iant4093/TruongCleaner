import CleanerCore
import Foundation
import Testing
@testable import CleanerScanner

/// `dev.projectArtifacts` end to end on a fixture tree: user-chosen roots, brace globs, sibling and
/// `.git` guards, and rows that are not walked (`computed`).
struct ProjectFolderScanTests {
    private let old = 60.0

    /// A file at `path` below the fixture home, with the folders above it up to `stopAt` dated `old` days back.
    private func oldTree(_ fixture: EngineFixture, _ path: String, pages: Int = 1) throws {
        try fixture.file(path, pages: pages, modified: fixture.days(old))
        var parts = path.split(separator: "/").map(String.init)
        parts.removeLast()
        while !parts.isEmpty {
            try fixture.tree.setModified("home/" + parts.joined(separator: "/"), to: fixture.days(old))
            parts.removeLast()
        }
    }

    private func scan(_ fixture: EngineFixture, folders: [URL]) async throws -> RuleResult {
        let rule = try #require(Catalog.all.first { $0.id == "dev.projectArtifacts" })
        let environment = Environment(home: fixture.home, now: fixture.environment.now, projectFolders: folders)
        let request = ScanRequest(rules: [rule], environment: environment)
        var report: ScanReport?
        for await event in await ScanEngine().scan(request) {
            if case .finished(let final) = event { report = final }
        }
        return try #require(report?.results.first)
    }

    @Test
    func offersOldArtifactsInsideProjectsOnly() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        // Offered: node_modules (with a nested one inside it) and a Rust target beside Cargo.toml.
        try oldTree(fixture, "Code/app/node_modules/pkg/index.js", pages: 2)
        try oldTree(fixture, "Code/app/node_modules/pkg/node_modules/dep/x.js")
        try oldTree(fixture, "Code/rust/Cargo.toml")
        try oldTree(fixture, "Code/rust/target/debug/a.o", pages: 3)
        // Not offered: directly in the chosen folder, target without Cargo.toml, a nested repository, a new one.
        try oldTree(fixture, "Code/node_modules/top/y.js")
        try oldTree(fixture, "Code/other/target/debug/b.o")
        try oldTree(fixture, "Code/vendored/node_modules/.git/HEAD")
        try fixture.file("Code/fresh/node_modules/z.js")

        let result = try await scan(fixture, folders: [fixture.url("Code")])

        let found = Set(result.findings.map(\.url.plainPath))
        #expect(found == [
            fixture.url("Code/app/node_modules").plainPath,
            fixture.url("Code/rust/target").plainPath,
        ])
        #expect(result.skippedCounts[.missingSibling] == 1)
        #expect(result.skippedCounts[.excludedName] == 1)
        #expect(result.skippedCounts[.tooNew] == 1)
        #expect(result.partial == false)
        // The nested node_modules is part of the outer one and is not counted twice.
        let modules = try #require(result.findings.first { $0.url.plainPath.hasSuffix("app/node_modules") })
        #expect(modules.allocatedBytes >= fixture.bytes(3))
        #expect(result.findings.count == 2)
    }

    @Test
    func noChosenFolderScansNothingAndIsNotPartial() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try oldTree(fixture, "Code/app/node_modules/pkg/index.js")

        let result = try await scan(fixture, folders: [])
        #expect(result.findings.isEmpty)
        #expect(result.partial == false)
        #expect(result.missingRoots.isEmpty)
    }

    @Test
    func aFolderThatIsNotThereIsReportedMissing() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let result = try await scan(fixture, folders: [fixture.url("Nowhere")])
        #expect(result.findings.isEmpty)
        #expect(result.missingRoots.map(\.lastPathComponent) == ["Nowhere"])
    }

    @Test
    func protectedAndTopLevelFoldersAreNeverScanned() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try oldTree(fixture, "Library/CloudStorage/Drive/app/node_modules/pkg/i.js")
        try oldTree(fixture, "Library/app/node_modules/pkg/i.js")

        // The home folder and ~/Library are dropped before anything is walked; CloudStorage is protected.
        let result = try await scan(fixture, folders: [
            fixture.home, fixture.url("Library"), fixture.url("Library/CloudStorage/Drive"),
        ])
        #expect(result.findings.isEmpty)
        #expect(result.missingRoots.isEmpty)
    }

    @Test
    func symlinksInsideAChosenFolderAreNotFollowed() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try oldTree(fixture, "elsewhere/app/node_modules/pkg/i.js")
        // A link inside the chosen folder is never followed.
        try fixture.tree.addDirectory("home/Code")
        try fixture.tree.addSymlink("home/Code/linked", destination: fixture.url("elsewhere"))

        let result = try await scan(fixture, folders: [fixture.url("Code")])
        #expect(result.findings.isEmpty)
    }

    @Test
    func computedRowsAreNotWalked() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let rule = Rule(
            id: "test.computed", category: .system, tier: .info, roots: [],
            match: .computed("test.computed"), access: .user, action: .none, title: "t", explain: "t")
        let (events, report) = await fixture.scan([rule])
        let result = try #require(fixture.result("test.computed", in: report))

        #expect(result.findings.isEmpty)
        #expect(result.measuredBytes == 0)
        #expect(result.partial == false)
        #expect(events.contains { if case .ruleStarted("test.computed") = $0 { true } else { false } })
    }

    @Test
    func catalogInfoRowsOverAFixtureHomeAreMeasuredOrLeftAlone() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Mail/V10/box.bin", pages: 3)
        try fixture.file("Library/Messages/Attachments/ab/pic.bin", pages: 2)
        let ids: Set<String> = ["mail.store", "mail.messagesAttachments", "system.snapshots"]
        let rules = Catalog.all.filter { ids.contains($0.id) }

        let (_, report) = await fixture.scan(rules)
        #expect(try #require(fixture.result("mail.store", in: report)).measuredBytes == fixture.bytes(3))
        #expect(try #require(fixture.result("mail.messagesAttachments", in: report)).measuredBytes == fixture.bytes(2))
        let snapshots = try #require(fixture.result("system.snapshots", in: report))
        #expect(snapshots.measuredBytes == 0)
        #expect(report.results.allSatisfy { $0.findings.isEmpty })
    }
}

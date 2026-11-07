import Foundation
import Testing
@testable import CleanerCore

/// Helpers and a compact view of outcomes.
private enum Fixture {
    static let rootPath = "/Users/tester/Library/Caches"
    static let root = URL(filePath: rootPath, directoryHint: .isDirectory)

    static func rule(
        id: String = "test.rule",
        tier: Tier = .safe,
        match: MatchSpec = .children,
        depth: Int = 1,
        guards: Guards = Guards(),
        rootComponents: [String] = ["Library", "Caches"]
    ) -> Rule {
        Rule(
            id: id,
            category: .caches,
            tier: tier,
            roots: [RootSpec(base: .home, components: rootComponents)],
            match: match,
            depth: depth,
            guards: guards,
            access: .user,
            action: tier == .info ? .none : .trash,
            title: "Test",
            explain: "Test rule"
        )
    }

    static func candidate(
        _ path: String,
        depth: Int = 1,
        isDirectory: Bool = true,
        isSymlink: Bool = false,
        modified: Date? = TestEnv.days(60),
        fileID: UInt64 = 1
    ) -> Candidate {
        Candidate(
            url: URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory),
            depth: depth,
            fsid: 7,
            fileID: fileID,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            flags: 0,
            allocatedBytes: 4096,
            privateBytes: 2048,
            itemCount: 3,
            newestModification: modified
        )
    }

    static func child(_ name: String, modified: Date? = TestEnv.days(60), fileID: UInt64 = 1) -> Candidate {
        candidate("\(rootPath)/\(name)", modified: modified, fileID: fileID)
    }

    static func evaluate(
        _ rule: Rule,
        root: URL = Fixture.root,
        _ candidates: [Candidate],
        siblings: [URL: Set<String>] = [:],
        exclusions: [URL] = []
    ) -> [MatchOutcome] {
        Matcher.evaluate(
            rule: rule, root: root, candidates: candidates, siblingNames: siblings,
            policy: TestEnv.policy(exclusions: exclusions), env: TestEnv.environment()
        )
    }

    /// `"name"` for a finding, `"name:reason"` for a skip.
    static func summary(_ outcomes: [MatchOutcome]) -> [String] {
        outcomes.map {
            switch $0 {
            case .finding(let finding): finding.url.lastPathComponent
            case .skipped(let candidate, let reason): "\(candidate.url.lastPathComponent):\(reason.rawValue)"
            }
        }
    }
}

struct MatcherTests {
    // MARK: - Basics

    @Test func childrenBecomeFindingsWithTheirIdentity() throws {
        let item = Fixture.candidate(
            "\(Fixture.rootPath)/com.example.app", modified: TestEnv.days(3), fileID: 99
        )
        let outcomes = Fixture.evaluate(Fixture.rule(id: "user.caches"), [item])
        let outcome = try #require(outcomes.first)
        guard case .finding(let finding) = outcome else {
            Issue.record("expected a finding")
            return
        }
        #expect(outcomes.count == 1)
        #expect(finding.ruleID == "user.caches")
        #expect(finding.url == item.url)
        #expect(finding.fsid == 7)
        #expect(finding.fileID == 99)
        #expect(finding.allocatedBytes == 4096)
        #expect(finding.privateBytes == 2048)
        #expect(finding.itemCount == 3)
        #expect(finding.flags == 0)
        #expect(finding.isDirectory)
        #expect(!finding.isSymlink)
        #expect(finding.newestModification == TestEnv.days(3))
    }

    @Test func outputKeepsInputOrder() {
        let outcomes = Fixture.evaluate(Fixture.rule(), [
            Fixture.child("c"), Fixture.child("a"), Fixture.child("b"),
        ])
        #expect(Fixture.summary(outcomes) == ["c", "a", "b"])
    }

    @Test func infoRuleSkipsEverything() {
        let outcomes = Fixture.evaluate(Fixture.rule(tier: .info, match: .measureOnly), [
            Fixture.child("a"),
            Fixture.candidate(Fixture.rootPath, depth: 0),
            Fixture.candidate("/elsewhere/x"),
        ])
        #expect(Fixture.summary(outcomes) == ["a:infoRule", "Caches:infoRule", "x:infoRule"])
    }

    @Test func infoTierWinsEvenWithAChildrenMatch() {
        let outcomes = Fixture.evaluate(Fixture.rule(tier: .info, match: .children), [Fixture.child("a")])
        #expect(Fixture.summary(outcomes) == ["a:infoRule"])
    }

    @Test func rulesThatWalkNothingNeverOfferCandidates() {
        let command = OwnerCommandSpec(executable: URL(filePath: "/usr/bin/true"), arguments: [], timeout: .seconds(1))
        let outcomes = Fixture.evaluate(Fixture.rule(match: .ownerCommand(command)), [Fixture.child("a")])
        #expect(Fixture.summary(outcomes) == ["a:infoRule"])
    }

    // MARK: - Individual checks

    @Test("The root itself is skipped", arguments: [0, 1])
    func rootItself(depth: Int) {
        let outcomes = Fixture.evaluate(Fixture.rule(), [Fixture.candidate(Fixture.rootPath, depth: depth)])
        #expect(Fixture.summary(outcomes) == ["Caches:isRoot"])
    }

    @Test func rootWithTrailingSlashAndDotDotIsStillTheRoot() {
        let outcomes = Fixture.evaluate(Fixture.rule(), [
            Fixture.candidate(Fixture.rootPath + "/", depth: 1),
            Fixture.candidate(Fixture.rootPath + "/x/..", depth: 1),
        ])
        #expect(outcomes.count == 2)
        for outcome in outcomes {
            guard case .skipped(_, let reason) = outcome else {
                Issue.record("expected a skip")
                continue
            }
            #expect(reason == .isRoot)
        }
    }

    @Test func homeAndLibraryAreRootsEvenIfARuleRootsThere() {
        let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
        let rule = Fixture.rule(rootComponents: [])
        let outcomes = Fixture.evaluate(rule, root: home, [
            Fixture.candidate("/Users/tester/Library"),
            Fixture.candidate("/Users/tester/Downloads"),
        ])
        #expect(Fixture.summary(outcomes) == ["Library:isRoot", "Downloads"])
    }

    @Test func outsideRootsIncludingPrefixSibling() {
        let outcomes = Fixture.evaluate(Fixture.rule(), [
            Fixture.candidate("/Users/tester/Library/Caches2/x"),
            Fixture.candidate("/Users/tester/Library/Other"),
            Fixture.candidate(Fixture.rootPath + "/../Other/x"),
        ])
        #expect(Fixture.summary(outcomes) == ["x:outsideRoots", "Other:outsideRoots", "x:outsideRoots"])
    }

    @Test func protectedPathsAreSkipped() {
        let outcomes = Fixture.evaluate(Fixture.rule(), [
            Fixture.child("CloudKit"),
            Fixture.child("com.apple.bird"),
            Fixture.child("com.example.app"),
        ])
        #expect(Fixture.summary(outcomes) == ["CloudKit:protectedPath", "com.apple.bird:protectedPath", "com.example.app"])
    }

    @Test func userExclusionIsSkippedAsProtected() {
        let outcomes = Fixture.evaluate(
            Fixture.rule(),
            [Fixture.child("keep.me"), Fixture.child("other")],
            exclusions: [Fixture.root.appending(path: "keep.me")]
        )
        #expect(Fixture.summary(outcomes) == ["keep.me:protectedPath", "other"])
    }

    @Test func excludedNames() {
        let rule = Fixture.rule(guards: Guards(excludeNames: ["Google", "firefox"]))
        let outcomes = Fixture.evaluate(rule, [Fixture.child("Google"), Fixture.child("Firefox"), Fixture.child("Mozilla")])
        #expect(Fixture.summary(outcomes) == ["Google:excludedName", "Firefox:excludedName", "Mozilla"])
    }

    @Test func excludedNameAnywhereOnTheRelativePath() {
        let rule = Fixture.rule(match: .glob("**"), depth: 3, guards: Guards(excludeNames: ["keep"]))
        let outcomes = Fixture.evaluate(rule, [
            Fixture.candidate(Fixture.rootPath + "/a/keep/b", depth: 3),
            Fixture.candidate(Fixture.rootPath + "/a/other/b", depth: 3),
        ])
        #expect(Fixture.summary(outcomes) == ["b:excludedName", "b"])
    }

    // MARK: - Symlinks

    @Test func symlinkChildIsAllowedForChildrenMatch() {
        let outcomes = Fixture.evaluate(Fixture.rule(), [Fixture.candidate(Fixture.rootPath + "/link", isSymlink: true)])
        #expect(Fixture.summary(outcomes) == ["link"])
        if case .finding(let finding) = outcomes.first {
            #expect(finding.isSymlink)
        } else {
            Issue.record("expected a finding")
        }
    }

    @Test func symlinkIsSkippedForFilesAndGlob() {
        let files = Fixture.rule(match: .files(extensions: ["log"]))
        let glob = Fixture.rule(match: .glob("*.log"))
        let link = Fixture.candidate(Fixture.rootPath + "/a.log", isDirectory: false, isSymlink: true)
        #expect(Fixture.summary(Fixture.evaluate(files, [link])) == ["a.log:symlinkNotAllowed"])
        #expect(Fixture.summary(Fixture.evaluate(glob, [link])) == ["a.log:symlinkNotAllowed"])
    }

    // MARK: - requiresSibling

    @Test func requiresSiblingWithAndWithoutCargoToml() {
        let projectA = URL(filePath: "/Users/tester/Library/Caches/a", directoryHint: .isDirectory)
        let projectB = URL(filePath: "/Users/tester/Library/Caches/b", directoryHint: .isDirectory)
        let rule = Fixture.rule(
            match: .glob("*/target"), depth: 2, guards: Guards(requiresSibling: ["Cargo.toml"])
        )
        let outcomes = Fixture.evaluate(
            rule,
            [
                Fixture.candidate(Fixture.rootPath + "/a/target", depth: 2),
                Fixture.candidate(Fixture.rootPath + "/b/target", depth: 2),
                Fixture.candidate(Fixture.rootPath + "/c/target", depth: 2),
            ],
            siblings: [projectA: ["Cargo.toml", "src", "target"], projectB: ["src", "target"]]
        )
        // c has no sibling list at all: unknown means keep.
        #expect(Fixture.summary(outcomes) == ["target", "target:missingSibling", "target:missingSibling"])
    }

    @Test func requiresSiblingAcceptsAnyListedName() {
        let parent = URL(filePath: "/Users/tester/Library/Caches/p", directoryHint: .isDirectory)
        let rule = Fixture.rule(
            match: .glob("*/build"), depth: 2,
            guards: Guards(requiresSibling: ["build.gradle", "CMakeLists.txt"])
        )
        let item = Fixture.candidate(Fixture.rootPath + "/p/build", depth: 2)
        #expect(Fixture.summary(Fixture.evaluate(rule, [item], siblings: [parent: ["CMakeLists.txt"]])) == ["build"])
        #expect(Fixture.summary(Fixture.evaluate(rule, [item], siblings: [parent: ["README.md"]])) == ["build:missingSibling"])
    }

    @Test func siblingLookupIgnoresTrailingSlashInKey() {
        let parent = URL(filePath: "/Users/tester/Library/Caches/p/", directoryHint: .isDirectory)
        let rule = Fixture.rule(match: .glob("*/target"), depth: 2, guards: Guards(requiresSibling: ["Cargo.toml"]))
        let item = Fixture.candidate(Fixture.rootPath + "/p/target", depth: 2)
        #expect(Fixture.summary(Fixture.evaluate(rule, [item], siblings: [parent: ["Cargo.toml"]])) == ["target"])
    }

    // MARK: - minAge

    @Test func minAgeKeepsNewItems() {
        let rule = Fixture.rule(guards: Guards(minAge: .seconds(7 * 86_400)))
        let outcomes = Fixture.evaluate(rule, [
            Fixture.child("old", modified: TestEnv.days(8)),
            Fixture.child("new", modified: TestEnv.days(6)),
            Fixture.child("exact", modified: TestEnv.days(7)),
            Fixture.child("future", modified: TestEnv.days(-1)),
        ])
        #expect(Fixture.summary(outcomes) == ["old", "new:tooNew", "exact:tooNew", "future:tooNew"])
    }

    @Test("Mole #1584: an unknown date is kept, not treated as old")
    func mole1584UnknownAgeIsKept() {
        let rule = Fixture.rule(guards: Guards(minAge: .seconds(86_400)))
        let outcomes = Fixture.evaluate(rule, [Fixture.child("mystery", modified: nil)])
        #expect(Fixture.summary(outcomes) == ["mystery:unknownAge"])
    }

    @Test func unknownDateIsFineWhenThereIsNoMinAge() {
        let outcomes = Fixture.evaluate(Fixture.rule(), [Fixture.child("mystery", modified: nil)])
        #expect(Fixture.summary(outcomes) == ["mystery"])
    }

    // MARK: - keepNewest

    @Test func keepNewestTwoAcrossTwoParents() {
        let rule = Fixture.rule(match: .glob("*/*"), depth: 2, guards: Guards(keepNewest: 2))
        func item(_ parent: String, _ name: String, _ age: Double) -> Candidate {
            Fixture.candidate("\(Fixture.rootPath)/\(parent)/\(name)", depth: 2, modified: TestEnv.days(age))
        }
        let outcomes = Fixture.evaluate(rule, [
            item("iOS", "16", 50), item("iOS", "17", 10), item("iOS", "15", 90), item("iOS", "18", 1),
            item("watchOS", "9", 30), item("watchOS", "10", 5), item("watchOS", "8", 60),
        ])
        // Each parent keeps its own two newest: iOS 18 and 17, watchOS 10 and 9.
        #expect(Fixture.summary(outcomes) == [
            "16", "17:keepNewest", "15", "18:keepNewest",
            "9:keepNewest", "10:keepNewest", "8",
        ])
    }

    @Test func keepNewestTreatsUnknownDateAsNewest() {
        let rule = Fixture.rule(guards: Guards(keepNewest: 1))
        let outcomes = Fixture.evaluate(rule, [
            Fixture.child("dated", modified: TestEnv.days(1)),
            Fixture.child("unknown", modified: nil),
        ])
        #expect(Fixture.summary(outcomes) == ["dated", "unknown:keepNewest"])
    }

    @Test func keepNewestCountsOnlySurvivors() {
        // "recent" fails minAge, so it does not use up one of the two kept slots.
        let rule = Fixture.rule(guards: Guards(minAge: .seconds(30 * 86_400), keepNewest: 1))
        let outcomes = Fixture.evaluate(rule, [
            Fixture.child("recent", modified: TestEnv.days(2)),
            Fixture.child("older", modified: TestEnv.days(40)),
            Fixture.child("oldest", modified: TestEnv.days(90)),
        ])
        #expect(Fixture.summary(outcomes) == ["recent:tooNew", "older:keepNewest", "oldest"])
    }

    @Test func keepNewestLargerThanGroupOffersNothing() {
        let rule = Fixture.rule(guards: Guards(keepNewest: 5))
        let outcomes = Fixture.evaluate(rule, [Fixture.child("a"), Fixture.child("b")])
        #expect(Fixture.summary(outcomes) == ["a:keepNewest", "b:keepNewest"])
    }

    // MARK: - Shape

    @Test func childrenIgnoresDeeperCandidates() {
        let outcomes = Fixture.evaluate(Fixture.rule(), [
            Fixture.child("a"),
            Fixture.candidate(Fixture.rootPath + "/a/b", depth: 2),
        ])
        #expect(Fixture.summary(outcomes) == ["a"])
    }

    @Test func filesMatchByExtensionAndDepth() {
        let rule = Fixture.rule(match: .files(extensions: ["log", ".IPS"]), depth: 2)
        let outcomes = Fixture.evaluate(rule, [
            Fixture.candidate(Fixture.rootPath + "/a.log", isDirectory: false),
            Fixture.candidate(Fixture.rootPath + "/b.IPS", isDirectory: false),
            Fixture.candidate(Fixture.rootPath + "/c.txt", isDirectory: false),
            Fixture.candidate(Fixture.rootPath + "/d.log", isDirectory: true),
            Fixture.candidate(Fixture.rootPath + "/x/e.log", depth: 2, isDirectory: false),
            Fixture.candidate(Fixture.rootPath + "/x/y/f.log", depth: 3, isDirectory: false),
        ])
        #expect(Fixture.summary(outcomes) == ["a.log", "b.IPS", "e.log"])
    }

    @Test func globMatchesRelativePath() {
        let rule = Fixture.rule(match: .glob("**/*.xcarchive"), depth: 3)
        let outcomes = Fixture.evaluate(rule, [
            Fixture.candidate(Fixture.rootPath + "/2026-01-01/App.xcarchive", depth: 2),
            Fixture.candidate(Fixture.rootPath + "/2026-01-01/App.zip", depth: 2),
            Fixture.candidate(Fixture.rootPath + "/Top.xcarchive", depth: 1),
        ])
        #expect(Fixture.summary(outcomes) == ["App.xcarchive", "Top.xcarchive"])
    }

    // MARK: - Order of checks

    @Test func orderOfChecks() {
        // Each candidate fails the named check and every later one.
        let rule = Fixture.rule(guards: Guards(
            minAge: .seconds(30 * 86_400), requiresSibling: ["marker"], excludeNames: ["bad"]
        ))
        let outcomes = Fixture.evaluate(rule, [
            Fixture.candidate(Fixture.rootPath, depth: 0, isSymlink: true, modified: nil),
            Fixture.candidate("/Users/tester/Library/Elsewhere/CloudKit", isSymlink: true, modified: nil),
            Fixture.candidate(Fixture.rootPath + "/CloudKit", isSymlink: true, modified: nil),
            Fixture.candidate(Fixture.rootPath + "/bad", isSymlink: true, modified: nil),
            Fixture.candidate(Fixture.rootPath + "/plain", modified: nil),
        ])
        #expect(Fixture.summary(outcomes) == [
            "Caches:isRoot", "CloudKit:outsideRoots", "CloudKit:protectedPath", "bad:excludedName", "plain:missingSibling",
        ])
    }

    @Test func excludedNameBeatsSiblingAndAge() {
        let rule = Fixture.rule(guards: Guards(minAge: .seconds(86_400 * 30), requiresSibling: ["m"], excludeNames: ["bad"]))
        let outcomes = Fixture.evaluate(rule, [Fixture.child("bad", modified: TestEnv.days(1))])
        #expect(Fixture.summary(outcomes) == ["bad:excludedName"])
    }

    @Test func siblingBeatsAge() {
        let parent = Fixture.root
        let rule = Fixture.rule(guards: Guards(minAge: .seconds(86_400 * 30), requiresSibling: ["m"]))
        let item = Fixture.child("x", modified: TestEnv.days(1))
        #expect(Fixture.summary(Fixture.evaluate(rule, [item], siblings: [parent: ["other"]])) == ["x:missingSibling"])
        #expect(Fixture.summary(Fixture.evaluate(rule, [item], siblings: [parent: ["m"]])) == ["x:tooNew"])
    }

    @Test func symlinkBeatsExcludedName() {
        let rule = Fixture.rule(match: .files(extensions: ["log"]), guards: Guards(excludeNames: ["a.log"]))
        let link = Fixture.candidate(Fixture.rootPath + "/a.log", isDirectory: false, isSymlink: true)
        #expect(Fixture.summary(Fixture.evaluate(rule, [link])) == ["a.log:symlinkNotAllowed"])
    }

    // MARK: - Incidents (docs/RESEARCH.md §3.3)

    @Test("Mole #823: agent memory under ~/.claude/projects is never offered")
    func mole823AgentMemoryNotOffered() {
        let root = URL(filePath: "/Users/tester/.claude/projects/my-app", directoryHint: .isDirectory)
        let rule = Fixture.rule(rootComponents: [".claude", "projects", "my-app"])
        let outcomes = Fixture.evaluate(rule, root: root, [
            Fixture.candidate(root.path() + "memory"),
            Fixture.candidate(root.path() + "session.jsonl", isDirectory: false),
        ])
        #expect(Fixture.summary(outcomes) == ["memory:protectedPath", "session.jsonl:protectedPath"])
    }

    @Test("Mole #1689: the DiagnosticReports folder itself is never offered, only what is inside")
    func mole1689RootFolderNotOffered() {
        let root = URL(filePath: "/Users/tester/Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
        let rule = Fixture.rule(
            match: .files(extensions: ["ips"]), guards: Guards(minAge: .seconds(7 * 86_400)),
            rootComponents: ["Library", "Logs", "DiagnosticReports"]
        )
        let outcomes = Fixture.evaluate(rule, root: root, [
            Fixture.candidate(root.path(), depth: 0, modified: TestEnv.days(30)),
            Fixture.candidate(root.path(), depth: 1, modified: TestEnv.days(30)),
            Fixture.candidate(root.path() + "old.ips", isDirectory: false, modified: TestEnv.days(30)),
        ])
        #expect(Fixture.summary(outcomes) == ["DiagnosticReports:isRoot", "DiagnosticReports:isRoot", "old.ips"])
    }
}

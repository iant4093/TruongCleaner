import Foundation
import Testing
@testable import CleanerCore

/// The five test obligations of `docs/RULE_CATALOG.md` §5, at the matcher level,
/// run for every rule in the catalog.
struct CatalogObligationTests {
    // MARK: - 1. Finds what it should, only inside its roots

    @Test("Offers an item inside each root and not one outside", arguments: CatalogFixture.workingRuleIDs)
    func insideAndOutsideRoots(id: String) throws {
        let rule = try CatalogFixture.rule(id)
        for root in try CatalogFixture.concreteRoots(rule) {
            let inside = try CatalogFixture.matching(rule, in: root, named: "item")
            let outsideParent = root.deletingLastPathComponent()
                .appending(path: root.lastPathComponent + "-other", directoryHint: .isDirectory)
            let outside = try CatalogFixture.matching(rule, in: outsideParent, named: "item")

            let outcomes = CatalogFixture.evaluate(rule, root: root, [inside, outside])
            #expect(outcomes.count == 2, "\(id) \(root.path())")
            #expect(CatalogFixture.findings(outcomes).map(\.url) == [inside.url], "\(id) \(root.path())")
            #expect(CatalogFixture.skipReasons(outcomes) == [.outsideRoots], "\(id) \(root.path())")
        }
    }

    @Test("Never offers its own root", arguments: CatalogFixture.workingRuleIDs)
    func rootItself(id: String) throws {
        let rule = try CatalogFixture.rule(id)
        for root in try CatalogFixture.concreteRoots(rule) {
            let outcomes = CatalogFixture.evaluate(rule, root: root, [
                CatalogFixture.candidate(root, depth: 0),
                CatalogFixture.candidate(root, depth: 1),
            ])
            #expect(CatalogFixture.findings(outcomes).isEmpty, "\(id) \(root.path())")
            #expect(CatalogFixture.skipReasons(outcomes) == [.isRoot, .isRoot], "\(id) \(root.path())")
        }
    }

    // MARK: - 2. Age, keep-newest and exclusion guards hold

    @Test("Keeps items newer than minAge and items with an unknown date", arguments: CatalogFixture.workingRuleIDs)
    func minAgeHolds(id: String) throws {
        let rule = try CatalogFixture.rule(id)
        guard let minAge = rule.guards.minAge else { return }
        let age = CatalogFixture.seconds(minAge)
        let root = try #require(try CatalogFixture.concreteRoots(rule).first)

        let fresh = try CatalogFixture.matching(rule, in: root, named: "fresh", modified: TestEnv.now.addingTimeInterval(-(age - 3600)))
        let unknown = try CatalogFixture.matching(rule, in: root, named: "unknown", modified: nil)
        let old = try CatalogFixture.matching(rule, in: root, named: "old", modified: TestEnv.now.addingTimeInterval(-(age + 3600)))

        let outcomes = CatalogFixture.evaluate(rule, root: root, [fresh, unknown, old])
        #expect(CatalogFixture.skipReasons(outcomes) == [.tooNew, .unknownAge])
        #expect(CatalogFixture.findings(outcomes).map(\.url) == [old.url])
    }

    @Test("Keeps the newest N matches", arguments: CatalogFixture.workingRuleIDs)
    func keepNewestHolds(id: String) throws {
        let rule = try CatalogFixture.rule(id)
        guard let keep = rule.guards.keepNewest else { return }
        let root = try #require(try CatalogFixture.concreteRoots(rule).first)
        let items = try (0..<(keep + 2)).map { index in
            try CatalogFixture.matching(rule, in: root, named: "item\(index)", modified: TestEnv.days(Double(100 + index)))
        }
        let outcomes = CatalogFixture.evaluate(rule, root: root, items)
        #expect(CatalogFixture.findings(outcomes).count == 2)
        #expect(CatalogFixture.skipReasons(outcomes) == Array(repeating: .keepNewest, count: keep))
    }

    @Test("Skips names the rule excludes", arguments: CatalogFixture.workingRuleIDs)
    func excludedNamesHold(id: String) throws {
        let rule = try CatalogFixture.rule(id)
        guard !rule.guards.excludeNames.isEmpty else { return }
        let root = try #require(try CatalogFixture.concreteRoots(rule).first)

        for name in rule.guards.excludeNames.sorted() {
            // A folder with that name directly below the root. For file rules the folder
            // holds the file, so the rule must look two levels deep.
            let candidate: Candidate
            switch rule.match {
            case .children:
                candidate = try CatalogFixture.matching(rule, in: root, named: name)
            default:
                try #require(rule.depth >= 2, "\(id): a file rule with excluded names needs depth 2")
                let folder = root.appending(path: name, directoryHint: .isDirectory)
                candidate = try CatalogFixture.matching(rule, in: folder, named: "item", depth: 2)
            }
            let outcomes = CatalogFixture.evaluate(rule, root: root, [candidate])
            #expect(CatalogFixture.skipReasons(outcomes) == [.excludedName], "\(id) \(name)")
        }
    }

    // MARK: - 3. Protected paths and user exclusions win

    @Test("Skips a user-excluded item", arguments: CatalogFixture.workingRuleIDs)
    func userExclusionWins(id: String) throws {
        let rule = try CatalogFixture.rule(id)
        for root in try CatalogFixture.concreteRoots(rule) {
            let excluded = try CatalogFixture.matching(rule, in: root, named: "excluded")
            let other = try CatalogFixture.matching(rule, in: root, named: "other")
            let outcomes = CatalogFixture.evaluate(rule, root: root, [excluded, other], exclusions: [excluded.url])
            #expect(CatalogFixture.skipReasons(outcomes) == [.protectedPath], "\(id) \(root.path())")
            #expect(CatalogFixture.findings(outcomes).map(\.url) == [other.url], "\(id) \(root.path())")
        }
    }

    @Test(
        "Skips protected folders that sit under a root",
        arguments: CatalogFixture.workingRuleIDs, ["HomeKit", "FamilyCircle", "1Password", "iZotope", "com.apple.homed"]
    )
    func protectedListWins(id: String, name: String) throws {
        let rule = try CatalogFixture.rule(id)
        for root in try CatalogFixture.concreteRoots(rule) {
            let url = root.appending(path: name, directoryHint: .isDirectory)
            try #require(TestEnv.policy().protectedReason(for: url) != nil, "\(name) must be protected anywhere")
            let outcomes = CatalogFixture.evaluate(rule, root: root, [CatalogFixture.candidate(url)])
            #expect(CatalogFixture.skipReasons(outcomes) == [.protectedPath], "\(id) \(root.path())")
        }
    }

    @Test("Skips protected Apple folders under the user cache folder")
    func protectedAppleFoldersUnderUserCaches() throws {
        let rule = try CatalogFixture.rule("user.caches")
        let root = try #require(try CatalogFixture.concreteRoots(rule).first)
        let names = ["CloudKit", "com.apple.bird", "com.apple.cloudd", "FileProvider", "com.apple.finder"]
        let candidates = names.map { CatalogFixture.candidate(root.appending(path: $0, directoryHint: .isDirectory)) }
        let outcomes = CatalogFixture.evaluate(rule, root: root, candidates)
        #expect(CatalogFixture.skipReasons(outcomes) == Array(repeating: .protectedPath, count: names.count))
    }

    // MARK: - 4. Symbolic links are never followed

    @Test("Handles a symbolic link by the matcher's rules", arguments: CatalogFixture.workingRuleIDs)
    func symlinkHandling(id: String) throws {
        let rule = try CatalogFixture.rule(id)
        for root in try CatalogFixture.concreteRoots(rule) {
            let link = try CatalogFixture.matching(rule, in: root, named: "link", isSymlink: true)
            let outcomes = CatalogFixture.evaluate(rule, root: root, [link])
            if case .children = rule.match {
                // A linked child is offered as a link. It is never opened: the candidate stays a link.
                let finding = try #require(CatalogFixture.findings(outcomes).first, "\(id) \(root.path())")
                #expect(finding.isSymlink)
                #expect(CatalogFixture.skipReasons(outcomes).isEmpty)
            } else {
                #expect(CatalogFixture.findings(outcomes).isEmpty, "\(id) \(root.path())")
                #expect(CatalogFixture.skipReasons(outcomes) == [.symlinkNotAllowed], "\(id) \(root.path())")
            }
        }
    }

    // MARK: - 5. Info rules never delete

    @Test("Info rules have no action and offer nothing", arguments: CatalogFixture.infoRuleIDs)
    func infoRulesOfferNothing(id: String) throws {
        let rule = try CatalogFixture.rule(id)
        #expect(rule.tier == .info)
        #expect(rule.action == .none)
        #expect(rule.match == .measureOnly)
        for root in try CatalogFixture.concreteRoots(rule) {
            let child = CatalogFixture.candidate(root.appending(path: "item", directoryHint: .isDirectory))
            let outcomes = CatalogFixture.evaluate(rule, root: root, [child, CatalogFixture.candidate(root, depth: 0)])
            #expect(CatalogFixture.findings(outcomes).isEmpty, "\(id) \(root.path())")
            #expect(CatalogFixture.skipReasons(outcomes) == [.infoRule, .infoRule], "\(id) \(root.path())")
        }
    }

    @Test("Placeholder rules offer nothing until their matching exists", arguments: CatalogFixture.inertRuleIDs.sorted())
    func placeholdersOfferNothing(id: String) throws {
        let rule = try CatalogFixture.rule(id)
        #expect(rule.match == .measureOnly)
        for root in try CatalogFixture.concreteRoots(rule) {
            let child = CatalogFixture.candidate(root.appending(path: "item", directoryHint: .isDirectory))
            let outcomes = CatalogFixture.evaluate(rule, root: root, [child])
            #expect(CatalogFixture.findings(outcomes).isEmpty, "\(id) \(root.path())")
        }
    }
}

import CleanerCore
import Foundation
import Testing
@testable import CleanerScanner

/// A broad rule must not offer an item that holds the root of a more specific rule in the same scan.
struct RuleOverlapTests {
    private let broad = makeRule("test.caches", roots: [["Library", "Caches"]])
    private let xcode = makeRule("test.xcode", roots: [["Library", "Caches", "com.apple.dt.Xcode"]])

    private func names(_ result: RuleResult?) -> [String] {
        result?.findings.map(\.name).sorted() ?? []
    }

    @Test(arguments: [true, false])
    func broaderRuleDropsTheItemThatIsAnotherRulesRoot(broaderFirst: Bool) async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.apple.dt.Xcode/x", pages: 2)
        try fixture.file("Library/Caches/com.apple.dt.Xcode/y", pages: 1)
        try fixture.file("Library/Caches/com.other.App/z", pages: 1)

        let (_, report) = await fixture.scan(broaderFirst ? [broad, xcode] : [xcode, broad])

        let broadResult = fixture.result("test.caches", in: report)
        #expect(names(broadResult) == ["com.other.App"])
        #expect(broadResult?.skippedCounts[.coveredByOtherRule] == 1)
        #expect(broadResult?.measuredBytes == fixture.bytes(1))
        let xcodeResult = fixture.result("test.xcode", in: report)
        #expect(names(xcodeResult) == ["x", "y"])
        #expect(xcodeResult?.measuredBytes == fixture.bytes(3))
        #expect(xcodeResult?.skippedCounts[.coveredByOtherRule] == nil)
        // Nothing was left for the old "same path twice" check to drop.
        #expect(report.duplicatesDropped == 0)
        #expect(report.partial == false)
    }

    @Test
    func anItemThatContainsTheOtherRulesRootIsDroppedToo() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        // The root is below the item, not equal to it.
        let media = makeRule("test.media", roots: [["Library", "Caches", "com.spotify.client", "Data"]])
        try fixture.file("Library/Caches/com.spotify.client/Data/song", pages: 3)
        try fixture.file("Library/Caches/com.spotify.client/Other/file", pages: 1)
        try fixture.file("Library/Caches/com.other.App/z", pages: 1)

        let (_, report) = await fixture.scan([broad, media])

        #expect(names(fixture.result("test.caches", in: report)) == ["com.other.App"])
        #expect(fixture.result("test.caches", in: report)?.skippedCounts[.coveredByOtherRule] == 1)
        #expect(names(fixture.result("test.media", in: report)) == ["song"])
    }

    @Test
    func anUnrelatedSiblingIsStillOffered() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.apple.dt.Xcode/x")
        // Same name prefix, not the same folder.
        try fixture.file("Library/Caches/com.apple.dt.Xcode2/x")
        try fixture.file("Library/Caches/com.apple.dt/x")
        try fixture.file("Library/Caches/Unrelated/x")

        let (_, report) = await fixture.scan([broad, xcode])

        #expect(names(fixture.result("test.caches", in: report)) == ["Unrelated", "com.apple.dt", "com.apple.dt.Xcode2"])
        #expect(fixture.result("test.caches", in: report)?.skippedCounts[.coveredByOtherRule] == 1)
    }

    @Test
    func withoutTheSpecificRuleTheBroadRuleOffersEverything() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.example.One/x")
        try fixture.file("Library/Caches/com.other.App/z")

        let (_, report) = await fixture.scan([broad])

        #expect(names(fixture.result("test.caches", in: report)) == ["com.example.One", "com.other.App"])
        #expect(fixture.result("test.caches", in: report)?.skippedCounts[.coveredByOtherRule] == nil)
    }

    @Test
    func aRuleIsNeverCoveredByItsOwnRoots() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let both = makeRule(
            "test.both", roots: [["Library", "Caches"], ["Library", "Caches", "com.example.One"]])
        try fixture.file("Library/Caches/com.example.One/x")

        let (_, report) = await fixture.scan([both])

        // The folder is offered from the first root and its child from the second. Each is kept by the rule itself.
        #expect(names(fixture.result("test.both", in: report)) == ["com.example.One", "x"])
        #expect(fixture.result("test.both", in: report)?.skippedCounts[.coveredByOtherRule] == nil)
    }

    @Test
    func aRootThatIsNotThereCoversNothing() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let missing = makeRule("test.missing", roots: [["Library", "Caches", "com.example.One", "DerivedData"]])
        try fixture.file("Library/Caches/com.example.One/x")

        let (_, report) = await fixture.scan([broad, missing])

        #expect(names(fixture.result("test.caches", in: report)) == ["com.example.One"])
        #expect(fixture.result("test.missing", in: report)?.missingRoots.isEmpty == false)
    }

    @Test
    func anInfoRowDoesNotTakeItemsFromARuleThatCanOfferThem() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let info = makeRule(
            "test.info", tier: .info, roots: [["Library", "Caches", "com.example.One"]], match: .measureOnly)
        try fixture.file("Library/Caches/com.example.One/x", pages: 2)

        let (_, report) = await fixture.scan([broad, info])

        #expect(names(fixture.result("test.caches", in: report)) == ["com.example.One"])
        #expect(fixture.result("test.info", in: report)?.measuredBytes == fixture.bytes(2))
    }

    @Test
    func catalogCacheRulesNoLongerOfferTheSameFolderTwice() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.apple.dt.Xcode/Index/a", pages: 2)
        try fixture.file("Library/Caches/Yarn/v6/b", pages: 1)
        try fixture.file("Library/Caches/org.swift.swiftpm/repos/c", pages: 1)
        try fixture.file("Library/Caches/com.other.App/d", pages: 1)
        let ids: Set<String> = ["user.caches", "dev.xcodeCaches", "dev.yarn", "dev.swiftpm"]
        let rules = Catalog.all.filter { ids.contains($0.id) }
        #expect(rules.count == ids.count)

        let (_, report) = await fixture.scan(rules)

        let caches = fixture.result("user.caches", in: report)
        #expect(names(caches) == ["com.other.App"])
        #expect(caches?.skippedCounts[.coveredByOtherRule] == 3)
        #expect(names(fixture.result("dev.xcodeCaches", in: report)) == ["Index"])
        #expect(names(fixture.result("dev.yarn", in: report)) == ["v6"])
        #expect(names(fixture.result("dev.swiftpm", in: report)) == ["repos"])
        // Every byte is offered by exactly one rule.
        let total = report.results.reduce(Int64(0)) { $0 + $1.measuredBytes }
        #expect(total == fixture.bytes(5))
        #expect(report.duplicatesDropped == 0)
    }

    @Test
    func aDisabledCatalogRuleStillKeepsItsFolderOutOfUserCaches() async throws {
        // Safety review 5: the scan holds only enabled rules. With `dev.yarn` and the others off, the
        // broad `user.caches` must not start offering their folders, with weaker owner guards.
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/Yarn/v6/a", pages: 2)
        try fixture.file("Library/Caches/CocoaPods/b", pages: 1)
        try fixture.file("Library/Caches/com.google.GoogleDrive/c", pages: 1)
        try fixture.file("Library/Caches/com.example.Other/d", pages: 1)
        let userCaches = try #require(Catalog.all.first { $0.id == "user.caches" })

        let (_, report) = await fixture.scan([userCaches])

        let result = fixture.result("user.caches", in: report)
        #expect(names(result) == ["com.example.Other"])
        #expect(result?.skippedCounts[.coveredByOtherRule] == 3)
        #expect(result?.measuredBytes == fixture.bytes(1))
    }

    @Test
    func planningStopsResolvingRootsOnceCancelled() async throws {
        // Scanner review 5: planning reads the file system, so Stop must reach it.
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/com.example.One/x")
        let request = ScanRequest(
            rules: [broad], environment: fixture.environment, userExclusions: [],
            maxConcurrentRoots: 2, workersPerRoot: 4)
        let task = Task { () -> (queued: Bool, partial: Bool) in
            while !Task.isCancelled { await Task.yield() }
            var plan = RunPlan(
                request: request, clock: ContinuousClock(), largestFirst: true, deliverEarly: true, emit: { _ in })
            plan.flush()
            return (plan.hasQueuedUnits, plan.results.first?.partial ?? false)
        }
        task.cancel()
        let planned = await task.value

        #expect(planned.queued == false)
        #expect(planned.partial == true)
    }

    // MARK: - RootOverlap on its own (no file system)

    private func overlap(_ roots: [[String]]) -> RootOverlap {
        let rules = roots.indices.map { makeRule("r\($0)", roots: [["x"]]) }
        let resolved = roots.map { paths in
            RuleRoots(roots: paths.map { URL(filePath: $0, directoryHint: .isDirectory) })
        }
        return RootOverlap(rules: rules, roots: resolved)
    }

    @Test
    func overlapComparesWholeComponentsAndIgnoresCase() {
        let index = overlap([["/h/Library/Caches"], ["/h/Library/Caches/com.apple.dt.Xcode"]])
        func covered(_ path: String, by rule: Int) -> Bool {
            index.isCovered(URL(filePath: path, directoryHint: .isDirectory), byRuleOtherThan: "r\(rule)")
        }
        // Equal and above.
        #expect(covered("/h/Library/Caches/com.apple.dt.Xcode", by: 0))
        #expect(covered("/h/Library/Caches/com.apple.dt.xcode/", by: 0))
        #expect(covered("/h/Library/Caches", by: 1))
        // A longer name that starts the same, a sibling, a child below the root.
        #expect(!covered("/h/Library/Caches/com.apple.dt.Xcode2", by: 0))
        #expect(!covered("/h/Library/Caches/com.apple.dt", by: 0))
        #expect(!covered("/h/Library/Caches/com.apple.dt.Xcode/Index", by: 0))
        // Never by the rule's own root.
        #expect(!covered("/h/Library/Caches/com.apple.dt.Xcode", by: 1))
    }

    @Test
    func overlapComposesDecomposedNames() {
        let index = overlap([["/h/Caches/caf\u{E9}"]])
        #expect(index.isCovered(URL(filePath: "/h/Caches/cafe\u{301}", directoryHint: .isDirectory), byRuleOtherThan: "other"))
    }
}

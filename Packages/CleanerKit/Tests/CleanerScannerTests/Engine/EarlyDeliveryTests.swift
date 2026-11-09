import CleanerCore
import Foundation
import Synchronization
import Testing
@testable import CleanerScanner

/// When a finished rule may be delivered ahead of earlier rules that are still running.
struct EarlyDeliveryTests {
    private func roots(_ paths: [String]) -> RuleRoots {
        var roots = RuleRoots()
        roots.roots = paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
        return roots
    }

    private func urls(_ paths: [String]) -> [URL] {
        paths.map { URL(filePath: $0) }
    }

    // MARK: ClaimGuard

    @Test
    func rulesWithSeparateRootsNeverWaitForEachOther() {
        let rules = [makeRule("a", roots: [["x"]]), makeRule("b", roots: [["y"]])]
        let guardian = ClaimGuard(rules: rules, roots: [roots(["/h/x"]), roots(["/h/y"])])

        #expect(guardian.mayDeliver(rule: 1, paths: urls(["/h/y/1"]), pending: { _ in true }))
    }

    @Test
    func aRuleWaitsWhenAnEarlierPendingRuleCouldOfferTheSamePath() {
        let rules = [makeRule("a", roots: [["x"]]), makeRule("b", roots: [["x"]])]
        let guardian = ClaimGuard(rules: rules, roots: [roots(["/h/x"]), roots(["/h/x"])])

        #expect(guardian.mayDeliver(rule: 1, paths: urls(["/h/x/one"]), pending: { $0 == 0 }) == false)
        #expect(guardian.mayDeliver(rule: 1, paths: urls(["/h/x/one"]), pending: { _ in false }))
    }

    @Test
    func theComparisonIgnoresCase() {
        let rules = [makeRule("a", roots: [["x"]]), makeRule("b", roots: [["X"]])]
        let guardian = ClaimGuard(rules: rules, roots: [roots(["/h/x"]), roots(["/h/X"])])

        #expect(guardian.mayDeliver(rule: 1, paths: urls(["/h/X/One"]), pending: { _ in true }) == false)
    }

    @Test
    func aChildrenRuleCannotOfferAPathTwoLevelsBelowItsRoot() {
        // Rule a offers each child of /h/Caches. Rule b offers each child of /h/Caches/Xcode.
        let rules = [makeRule("a", roots: [["Caches"]]), makeRule("b", roots: [["Caches", "Xcode"]])]
        let guardian = ClaimGuard(rules: rules, roots: [roots(["/h/Caches"]), roots(["/h/Caches/Xcode"])])

        #expect(guardian.mayDeliver(rule: 1, paths: urls(["/h/Caches/Xcode/Data"]), pending: { _ in true }))
    }

    @Test
    func aDeeperRuleOffersPathsDownToItsDepth() {
        let rules = [
            makeRule("a", roots: [["Logs"]], match: .files(extensions: ["log"]), depth: 3),
            makeRule("b", roots: [["Logs"]]),
        ]
        let guardian = ClaimGuard(rules: rules, roots: [roots(["/h/Logs"]), roots(["/h/Logs"])])

        #expect(guardian.mayDeliver(rule: 1, paths: urls(["/h/Logs/a/b/c"]), pending: { $0 == 0 }) == false)
        #expect(guardian.mayDeliver(rule: 1, paths: urls(["/h/Logs/a/b/c/d"]), pending: { $0 == 0 }))
    }

    @Test
    func infoRulesAndRulesWithoutRootsNeverBlock() {
        let rules = [
            makeRule("info", tier: .info, roots: [["x"]], match: .measureOnly),
            makeRule("empty", roots: [["x"]]),
            makeRule("b", roots: [["x"]]),
        ]
        let guardian = ClaimGuard(rules: rules, roots: [roots(["/h/x"]), RuleRoots(), roots(["/h/x"])])

        #expect(guardian.mayDeliver(rule: 2, paths: urls(["/h/x/one"]), pending: { _ in true }))
    }

    @Test
    func aRuleWithNothingFoundGoesAtOnce() {
        let rules = [makeRule("a", roots: [["x"]]), makeRule("b", roots: [["x"]])]
        let guardian = ClaimGuard(rules: rules, roots: [roots(["/h/x"]), roots(["/h/x"])])

        #expect(guardian.mayDeliver(rule: 1, paths: [], pending: { _ in true }))
    }

    // MARK: Engine

    // Ordering under load is not guaranteed on shared CI runners; the property is checked locally.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] != "true"))
    func aSmallRuleIsDeliveredBeforeAnEarlierSlowRule() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let tree = fixture.tree
        try await onSetupQueue {
            for index in 0..<10 {
                try tree.addEmptyFiles(in: "home/Library/Big/dir\(index)", count: 500)
            }
        }
        try fixture.file("Library/Small/app/one.bin", pages: 1)
        let rules = [
            makeRule("test.big", roots: [["Library", "Big"]]),
            makeRule("test.small", roots: [["Library", "Small"]]),
        ]

        let (events, report) = await fixture.scan(rules, roots: 2, workers: 2)

        let order = events.compactMap { event -> String? in
            if case .ruleFinished(let result) = event { result.ruleID } else { nil }
        }
        #expect(order == ["test.small", "test.big"])
        #expect(report.results.map(\.ruleID) == ["test.big", "test.small"])
    }

    @Test
    func rulesThatShareAPathAreDeliveredInRequestOrderAndTheFirstKeepsIt() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Caches/one/a.bin", pages: 1)
        try fixture.file("Library/Caches/two/b.bin", pages: 2)
        let rules = [
            makeRule("test.first", roots: [["Library", "Caches"]]),
            makeRule("test.second", roots: [["Library", "Caches"]], match: .glob("*")),
            makeRule("test.third", roots: [["Library", "Caches"]]),
        ]

        for _ in 0..<5 {
            let (events, report) = await fixture.scan(rules, roots: 3, workers: 2)
            let order = events.compactMap { event -> String? in
                if case .ruleFinished(let result) = event { result.ruleID } else { nil }
            }
            #expect(order == ["test.first", "test.second", "test.third"])
            #expect(report.results[0].findings.map(\.name) == ["one", "two"])
            #expect(report.results[1].findings.isEmpty)
            #expect(report.results[2].findings.isEmpty)
            #expect(report.duplicatesDropped == 4)
        }
    }

    @Test
    func aRuleWithNoRootIsStartedAndFinishedAtOnce() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        let rules = [makeRule("test.missing", roots: [["Library", "Nope"]])]

        let (events, report) = await fixture.scan(rules)

        let tags = events.compactMap { event -> String? in
            switch event {
            case .ruleStarted(let id): "started \(id)"
            case .ruleFinished(let result): "finished \(result.ruleID)"
            case .finished: "report"
            case .progress: nil
            }
        }
        #expect(tags == ["started test.missing", "finished test.missing", "report"])
        #expect(report.results.first?.missingRoots.count == 1)
    }

    @Test
    func theBiggestRootStartsFirst() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/Few/a/f.bin", pages: 1)
        for index in 0..<40 {
            try fixture.file("Library/Many/item\(index)/f.bin", pages: 1)
        }
        let rules = [
            makeRule("test.few", roots: [["Library", "Few"]]),
            makeRule("test.many", roots: [["Library", "Many"]]),
        ]

        let (events, _) = await fixture.scan(rules, roots: 1, workers: 1)

        let started = events.compactMap { event -> String? in
            if case .ruleStarted(let id) = event { id } else { nil }
        }
        #expect(started == ["test.many", "test.few"])
    }

    @Test
    func requestOrderIsKeptWhenRootsAreEqualInSize() async throws {
        let fixture = try EngineFixture()
        defer { fixture.remove() }
        try fixture.file("Library/A/x/f.bin")
        try fixture.file("Library/B/x/f.bin")
        let rules = [makeRule("test.a", roots: [["Library", "A"]]), makeRule("test.b", roots: [["Library", "B"]])]

        let (events, _) = await fixture.scan(rules, roots: 1, workers: 1)

        let started = events.compactMap { event -> String? in
            if case .ruleStarted(let id) = event { id } else { nil }
        }
        #expect(started == ["test.a", "test.b"])
    }

    private func onSetupQueue(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

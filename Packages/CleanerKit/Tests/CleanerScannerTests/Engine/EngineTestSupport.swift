import CleanerCore
import CleanerTestSupport
import Foundation
@testable import CleanerScanner

/// A fixture "home" for engine tests. Every path a rule can reach is inside the fixture tree.
struct EngineFixture {
    /// 4 KB: APFS allocation unit, so file sizes in whole pages have exact expected totals.
    static let page = 4096

    let tree: FixtureTree
    let home: URL
    let environment: Environment

    init(now: Date = Date(), filePath: StaticString = #filePath) throws {
        tree = try FixtureTree(filePath: filePath)
        _ = try tree.addDirectory("home")
        home = tree.url(for: "home")
        environment = Environment(home: home, now: now)
    }

    func remove() { tree.remove() }

    /// Allocated bytes of `pages` pages.
    func bytes(_ pages: Int) -> Int64 { Int64(pages * Self.page) }

    /// A file of `pages` pages at a path relative to the fixture home.
    @discardableResult
    func file(_ path: String, pages: Int = 1, modified: Date? = nil) throws -> URL {
        try tree.addFile("home/" + path, size: pages * Self.page, modified: modified)
    }

    func url(_ path: String) -> URL { tree.url(for: "home/" + path) }

    func days(_ count: Double) -> Date { environment.now.addingTimeInterval(-count * 86_400) }

    /// Runs a scan through the public stream and returns every event.
    func scan(
        _ rules: [Rule], exclusions: [URL] = [], roots: Int = 2, workers: Int = 4
    ) async -> (events: [ScanEvent], report: ScanReport) {
        let request = ScanRequest(
            rules: rules, environment: environment, userExclusions: exclusions,
            maxConcurrentRoots: roots, workersPerRoot: workers)
        var events: [ScanEvent] = []
        var report: ScanReport?
        for await event in await ScanEngine().scan(request) {
            events.append(event)
            if case .finished(let final) = event { report = final }
        }
        guard let report else { preconditionFailure("stream ended without .finished") }
        return (events, report)
    }

    /// The result for one rule ID.
    func result(_ id: String, in report: ScanReport) -> RuleResult? {
        report.results.first { $0.ruleID == id }
    }
}

/// Builds a test rule. The catalog is not written yet, so tests define their own.
func makeRule(
    _ id: String,
    tier: Tier = .safe,
    roots: [[String]],
    match: MatchSpec = .children,
    depth: Int = 1,
    guards: Guards = Guards()
) -> Rule {
    Rule(
        id: id,
        category: .caches,
        tier: tier,
        roots: roots.map { RootSpec(base: .home, components: $0) },
        match: match,
        depth: depth,
        guards: guards,
        access: .user,
        action: tier == .info ? .none : .trash,
        title: "\(id)",
        explain: "Test rule."
    )
}

extension Finding {
    /// Last path component, for readable expectations.
    var name: String { url.lastPathComponent }
}

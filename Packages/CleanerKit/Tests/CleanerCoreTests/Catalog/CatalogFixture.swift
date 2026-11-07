import Foundation
import Testing
@testable import CleanerCore

/// Pure helpers for the catalog tests. Paths are text under `/Users/tester`; nothing is read from disk.
enum CatalogFixture {
    /// Name of every inert placeholder: a non-Info rule whose match is `.measureOnly`, so the
    /// matcher never offers anything for it. Adding or removing one must be a deliberate change here.
    static let inertRuleIDs: Set<String> = [
        "user.containerCaches", "user.groupContainerCaches", "trash.ours", "trash.volumes",
    ]

    static func rule(_ id: String) throws -> Rule {
        try #require(Catalog.all.first { $0.id == id }, "rule \(id) is missing from the catalog")
    }

    static var workingRuleIDs: [String] {
        Catalog.all.filter { $0.tier != .info && !inertRuleIDs.contains($0.id) }.map(\.id)
    }

    static var infoRuleIDs: [String] {
        Catalog.all.filter { $0.tier == .info }.map(\.id)
    }

    /// Roots of a rule as concrete folders: a `*` in a wildcard component becomes `x`.
    static func concreteRoots(_ rule: Rule) throws -> [URL] {
        try rule.roots.map { spec in
            let expanded = try #require(
                RootExpansion.expand(spec, in: TestEnv.environment()),
                "root of \(rule.id) does not expand"
            )
            return expanded.pattern.reduce(expanded.base) { url, component in
                url.appending(path: component.replacing("*", with: "x"), directoryHint: .isDirectory)
            }
        }
    }

    static func candidate(
        _ url: URL,
        depth: Int = 1,
        isDirectory: Bool = true,
        isSymlink: Bool = false,
        modified: Date? = TestEnv.days(400)
    ) -> Candidate {
        Candidate(
            url: url,
            depth: depth,
            fsid: 7,
            fileID: 1,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            flags: 0,
            allocatedBytes: 4096,
            privateBytes: 2048,
            itemCount: 1,
            newestModification: modified
        )
    }

    /// A candidate of the shape the rule matches, directly below `parent`:
    /// a folder for `.children`, a file with the first allowed extension for `.files`.
    static func matching(
        _ rule: Rule,
        in parent: URL,
        named name: String,
        depth: Int = 1,
        isSymlink: Bool = false,
        modified: Date? = TestEnv.days(400)
    ) throws -> Candidate {
        switch rule.match {
        case .children:
            return candidate(
                parent.appending(path: name, directoryHint: .isDirectory),
                depth: depth, isSymlink: isSymlink, modified: modified
            )
        case .files(let extensions):
            let ext = try #require(extensions.sorted().first)
            return candidate(
                parent.appending(path: "\(name).\(ext)", directoryHint: .notDirectory),
                depth: depth, isDirectory: false, isSymlink: isSymlink, modified: modified
            )
        case .glob, .ownerCommand, .measureOnly:
            Issue.record("\(rule.id): the catalog tests do not build candidates for this match kind")
            throw CancellationError()
        }
    }

    static func evaluate(
        _ rule: Rule,
        root: URL,
        _ candidates: [Candidate],
        exclusions: [URL] = []
    ) -> [MatchOutcome] {
        Matcher.evaluate(
            rule: rule,
            root: root,
            candidates: candidates,
            siblingNames: [:],
            policy: TestEnv.policy(exclusions: exclusions),
            env: TestEnv.environment()
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

    static func skipReasons(_ outcomes: [MatchOutcome]) -> [SkipReason] {
        outcomes.compactMap {
            if case .skipped(_, let reason) = $0 { reason } else { nil }
        }
    }

    static func findings(_ outcomes: [MatchOutcome]) -> [Finding] {
        outcomes.compactMap {
            if case .finding(let finding) = $0 { finding } else { nil }
        }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
    }
}

import Foundation
import Testing
@testable import CleanerCore

/// Pure helpers for the catalog tests. Paths are text under `/Users/tester`; nothing is read from disk.
enum CatalogFixture {
    /// Name of every inert placeholder: a non-Info rule whose match is `.measureOnly`, so the
    /// matcher never offers anything for it. Adding or removing one must be a deliberate change here.
    /// `trash.ours` waits for the history file (3.3). `trash.volumes` waits for a user-ID root base:
    /// `/Volumes/*/.Trashes/<uid>` cannot be written as a `RootSpec` without also reaching other users.
    static let inertRuleIDs: Set<String> = ["trash.ours", "trash.volumes"]

    static func rule(_ id: String) throws -> Rule {
        try #require(Catalog.all.first { $0.id == id }, "rule \(id) is missing from the catalog")
    }

    /// Rules that walk folders and offer items: not Info, not an inert placeholder, not an owner command.
    static var workingRuleIDs: [String] {
        Catalog.all.filter { $0.tier != .info && !inertRuleIDs.contains($0.id) && !isOwnerCommand($0) }.map(\.id)
    }

    /// Rules whose match is an owner command: nothing is walked, the owner's tool does the work.
    static var ownerCommandRuleIDs: [String] {
        Catalog.all.filter(isOwnerCommand).map(\.id)
    }

    static func isOwnerCommand(_ rule: Rule) -> Bool {
        if case .ownerCommand = rule.match { true } else { false }
    }

    /// A relative path (below the root) that a `.glob` rule matches, for a given item name.
    /// The last entry is the matched item. Rules with a glob match need a row here.
    private static let globSamples: [String: @Sendable (String) -> [String]] = [
        "dev.xcodeArchives": { ["2025-01-01", "\($0).xcarchive"] },
        "dev.projectArtifacts": { [$0, "node_modules"] },
        "installers.macOS": { ["Install macOS \($0).app"] },
        "installers.partial": { ["\($0).crdownload"] },
    ]

    static var infoRuleIDs: [String] {
        Catalog.all.filter { $0.tier == .info }.map(\.id)
    }

    /// Roots of a rule as concrete folders: a `*` in a wildcard component becomes `x`.
    static func concreteRoots(_ rule: Rule) throws -> [URL] {
        let env = TestEnv.environment()
        return try rule.roots.flatMap { spec in
            try RootExpansion.starts(of: spec, in: env).map { start in
                let expanded = try #require(
                    RootExpansion.expand(spec, from: start),
                    "root of \(rule.id) does not expand"
                )
                return expanded.pattern.reduce(expanded.base) { url, component in
                    url.appending(path: component.replacing("*", with: "x"), directoryHint: .isDirectory)
                }
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
        case .glob:
            let sample = try #require(globSamples[rule.id], "\(rule.id): add a row to globSamples")
            let relative = sample(name)
            let url = relative.reduce(parent) { $0.appending(path: $1, directoryHint: .inferFromPath) }
            return candidate(
                url, depth: depth - 1 + relative.count, isSymlink: isSymlink, modified: modified
            )
        case .ownerCommand, .measureOnly, .computed:
            Issue.record("\(rule.id): the catalog tests do not build candidates for this match kind")
            throw CancellationError()
        }
    }

    /// Runs the matcher for one root.
    ///
    /// A rule with `keepNewest` always keeps its newest matches, which would hide a lone test item.
    /// Unless `padKeepNewest` is false, that many newer children are added first and dropped from
    /// the result again, so the items a test passes in are judged on their own merits.
    static func evaluate(
        _ rule: Rule,
        root: URL,
        _ candidates: [Candidate],
        exclusions: [URL] = [],
        listings: [URL: Set<String>] = [:],
        padKeepNewest: Bool = true
    ) -> [MatchOutcome] {
        var all = candidates
        if padKeepNewest, let keep = rule.guards.keepNewest, case .children = rule.match {
            for index in 0..<keep {
                let url = root.appending(path: "\(padPrefix)\(index)", directoryHint: .isDirectory)
                all.append(candidate(url, modified: TestEnv.days(1)))
            }
        }
        let outcomes = Matcher.evaluate(
            rule: rule,
            root: root,
            candidates: all,
            siblingNames: listings,
            policy: TestEnv.policy(exclusions: exclusions),
            env: TestEnv.environment()
        )
        return outcomes.filter { outcome in
            let url: URL
            switch outcome {
            case .finding(let finding): url = finding.url
            case .skipped(let candidate, _): url = candidate.url
            }
            return !url.lastPathComponent.hasPrefix(padPrefix)
        }
    }

    private static let padPrefix = "zz-pad-"

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

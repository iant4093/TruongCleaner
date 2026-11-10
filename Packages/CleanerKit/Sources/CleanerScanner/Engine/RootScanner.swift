import CleanerCore
import Foundation

/// What walking and matching one root produced.
struct RootOutcome: Sendable {
    var findings: [Finding] = []
    var skipped: [SkipReason: Int] = [:]
    var measuredBytes: Int64 = 0
    var measuredPrivateBytes: Int64 = 0
    var needsAccess: [URL] = []
    var missing: [URL] = []
    var partial = false
}

/// Shared, read-only inputs for every root walk in one scan.
struct ScanContext: Sendable {
    let policy: PathPolicy
    let environment: Environment
    /// Most threads one walk may use. With a `budget` the walk starts with one and grows.
    let workers: Int
    /// Thread budget shared by all walks of the scan, or nil for a fixed number of threads per walk.
    let budget: WorkerBudget?
    /// Whether `.glob` rules leave folders unopened that cannot hold a match (`DescentFilter`).
    let globDescent: Bool
    let progress: ProgressAggregator
}

/// Which nodes of a walk become candidates, and how deep the walk keeps totals.
private enum Shape {
    case measure
    case children(totalsDepth: Int)
    case glob(GlobPattern, totalsDepth: Int)
    case files(Set<String>, totalsDepth: Int)

    var totalsDepth: Int {
        switch self {
        case .measure: 0
        case .children(let depth), .glob(_, let depth), .files(_, let depth): depth
        }
    }

    /// nil for rules that are not walked (`ownerCommand`, `computed`).
    init?(_ rule: Rule) {
        let depth = max(1, rule.depth)
        switch rule.match {
        case .ownerCommand, .computed:
            return nil
        case .measureOnly:
            self = .measure
        case _ where rule.tier == .info:
            self = .measure
        case .children:
            self = .children(totalsDepth: depth)
        case .glob(let text):
            let pattern = GlobPattern(text)
            let parts = text.split(separator: "/", omittingEmptySubsequences: true)
            let natural = parts.contains("**") ? depth : parts.count
            self = .glob(pattern, totalsDepth: max(1, natural))
        case .files(let extensions):
            let wanted = Set(extensions.map { Shape.fold($0.hasPrefix(".") ? String($0.dropFirst()) : $0) })
            self = .files(wanted, totalsDepth: depth)
        }
    }

    static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// Walks one root and turns what it finds into findings.
enum RootScanner {
    /// Most paths kept in `needsAccess` per root.
    static let accessCap = 50

    /// Walks `root` with `BulkWalker`, builds candidates and runs `Matcher.evaluate`.
    ///
    /// Reads only. A walk that stopped early marks the outcome partial. Where the rule has an age
    /// guard (`minAge`, `keepNewest`), candidates whose dates cannot be trusted (partial walk, or a
    /// folder inside that macOS would not open) get no date, so the matcher keeps them.
    static func scan(rule: Rule, root: URL, slot: Int, context: ScanContext) async -> RootOutcome {
        var outcome = RootOutcome()
        guard let shape = Shape(rule) else { return outcome }
        guard !Task.isCancelled else {
            outcome.partial = true
            return outcome
        }

        let prune = GlobPrune(rule: rule)
        var options = WalkOptions(
            maxWorkers: context.workers,
            totalsDepth: shape.totalsDepth,
            topFilesCount: 0,
            pruneNames: prune.names,
            pruneKeepNames: prune.keepNames
        )
        options.budget = context.budget
        // The matcher reads the names beside an item for these guards, so every folder must be listed.
        if context.globDescent, !rule.guards.needsFolderListings {
            options.descent = DescentFilter(rule: rule)
        }
        let progress = context.progress
        let result: WalkResult
        do {
            result = try await BulkWalker.walk(root, options: options) { update in
                progress.update(slot: slot, files: update.files, bytes: update.allocatedBytes)
            }
        } catch let error as ScanError {
            switch error {
            case .accessDenied(let url): outcome.needsAccess.append(url)
            case .notADirectory: outcome.missing.append(root)
            case .cannotOpen(_, let code) where code == ENOENT: outcome.missing.append(root)
            case .cannotOpen: outcome.partial = true
            }
            return outcome
        } catch {
            outcome.partial = true
            return outcome
        }

        let rootTotals = result.nodes.first
        progress.finish(slot: slot, files: result.files, bytes: rootTotals?.allocatedBytes ?? 0)
        outcome.needsAccess = Array(result.deniedDirectories.prefix(accessCap))
        // Entries dropped for a reason other than permission (EIO, EMFILE, a failed listing) make the totals
        // too low and the dates incomplete, so the result is partial and no date is trusted.
        outcome.partial = result.isIncomplete || Task.isCancelled

        if case .measure = shape {
            outcome.measuredBytes = rootTotals?.allocatedBytes ?? 0
            outcome.measuredPrivateBytes = rootTotals?.privateBytes ?? 0
            return outcome
        }

        let candidates = candidates(from: result, shape: shape, rule: rule, datesUntrusted: outcome.partial)
        let siblings = rule.guards.needsFolderListings ? siblingNames(in: result) : [:]
        let outcomes = Matcher.evaluate(
            rule: rule,
            root: root,
            candidates: candidates,
            siblingNames: siblings,
            policy: context.policy,
            env: context.environment
        )
        for item in outcomes {
            switch item {
            case .finding(let finding): outcome.findings.append(finding)
            case .skipped(_, let reason): outcome.skipped[reason, default: 0] += 1
            }
        }
        return outcome
    }

    // MARK: - Candidates

    private static func candidates(
        from result: WalkResult, shape: Shape, rule: Rule, datesUntrusted: Bool
    ) -> [Candidate] {
        let rootPath = result.root.path(percentEncoded: false)
        let maxDepth = max(1, rule.depth)
        let hasAgeGuard = rule.guards.minAge != nil || (rule.guards.keepNewest ?? 0) > 0
        let taint = hasAgeGuard ? Taint(result: result, depth: shape.totalsDepth, all: datesUntrusted) : nil

        var candidates: [Candidate] = []
        for node in result.nodes where node.depth >= 1 {
            switch shape {
            case .measure:
                return []
            case .children:
                if node.depth != 1 { continue }
            case .files(let extensions, _):
                guard node.kind == .file, node.depth <= maxDepth,
                      extensions.contains(Shape.fold(node.url.pathExtension))
                else { continue }
            case .glob(let pattern, _):
                guard node.depth <= maxDepth,
                      let relative = relativeComponents(of: node.url, below: rootPath),
                      pattern.matches(relative.map(Shape.fold))
                else { continue }
            }
            let untrusted = taint?.covers(node.url) ?? false
            candidates.append(
                Candidate(
                    url: node.url,
                    depth: node.depth,
                    fsid: node.id.fsid,
                    fileID: node.id.fileID,
                    isDirectory: node.kind == .directory,
                    isSymlink: node.kind == .symlink,
                    flags: node.flags,
                    allocatedBytes: node.allocatedBytes,
                    privateBytes: node.privateBytes,
                    itemCount: node.fileCount,
                    newestModification: untrusted ? nil : node.newestModification
                )
            )
        }
        return candidates
    }

    private static func relativeComponents(of url: URL, below rootPath: String) -> [String]? {
        let path = url.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Names of the kept nodes in each folder, for `requiresSibling`.
    private static func siblingNames(in result: WalkResult) -> [URL: Set<String>] {
        var names: [URL: Set<String>] = [:]
        for node in result.nodes where node.depth >= 1 {
            names[node.url.deletingLastPathComponent(), default: []].insert(node.url.lastPathComponent)
        }
        return names
    }

    /// Entries whose newest date cannot be trusted because something inside was unreadable.
    private struct Taint {
        private let paths: Set<String>
        private let all: Bool

        init(result: WalkResult, depth: Int, all: Bool) {
            let rootPath = result.root.plainPath
            let prefix = rootPath == "/" ? rootPath : rootPath + "/"
            var tainted = Set<String>()
            // More denied folders than were listed: any entry may hold one.
            let everything = all || result.deniedCount > result.deniedDirectories.count
            if !everything {
                // A denied folder taints itself and every ancestor the walk keeps a total for.
                for denied in result.deniedDirectories {
                    let path = denied.plainPath
                    guard path.hasPrefix(prefix) else { continue }
                    let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true)
                    var current = rootPath == "/" ? "" : rootPath
                    for part in parts.prefix(depth) {
                        current += "/" + part
                        tainted.insert(current)
                    }
                }
            }
            self.paths = tainted
            self.all = everything
        }

        func covers(_ url: URL) -> Bool {
            all || paths.contains(url.plainPath)
        }
    }
}

extension URL {
    /// The file path without a trailing slash. Folder URLs from the walker end in `/`; file URLs do not.
    var plainPath: String {
        var path = path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

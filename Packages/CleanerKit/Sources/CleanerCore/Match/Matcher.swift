import Foundation

/// Turns the entries a scan found under one root into findings and skips.
///
/// Pure: no file system access. Everything it needs about folders (the names
/// beside an item) comes in as values. Unknown means keep: a missing date or a
/// missing sibling list skips the item.
public enum Matcher {
    private enum Verdict {
        /// Does not fit the rule's shape (wrong depth, name or kind). No outcome.
        case notMatched
        case skip(SkipReason)
        case keep
    }

    /// Applies a rule's match, depth and guards (`minAge`, `keepNewest`,
    /// `excludeNames`, `requiresSibling`) and the path policy to candidates found
    /// under one expanded root.
    ///
    /// Checks run in this order and the first failure decides: Info rule, root
    /// itself, outside the root, protected path, (shape: candidates that do not
    /// fit the match spec or depth are left out), symlink, excluded name,
    /// required sibling, age, and last `keepNewest` across the survivors.
    ///
    /// - `requiresSibling` is satisfied when at least one of the listed names is
    ///   present beside the item ("a build file beside `build`").
    /// - `minAge`: the item must be strictly older than `minAge`.
    /// - `keepNewest`: groups are the item's parent folder; an unknown date sorts as newest.
    /// - `.ownerCommand` and `.measureOnly` rules walk nothing, so any candidate
    ///   handed in is skipped as `.infoRule`.
    ///
    /// - Parameters:
    ///   - rule: The rule being evaluated.
    ///   - root: One expanded, concrete root of the rule.
    ///   - candidates: Entries found under `root`.
    ///   - siblingNames: For a candidate's parent folder, the names present in it.
    ///   - policy: Protected list, user exclusions and root checks.
    ///   - env: Supplies the current time.
    /// - Returns: Outcomes in input order, without the candidates that did not fit the rule's shape.
    public static func evaluate(
        rule: Rule,
        root: URL,
        candidates: [Candidate],
        siblingNames: [URL: Set<String>],
        policy: PathPolicy,
        env: Environment
    ) -> [MatchOutcome] {
        if rule.tier == .info {
            return candidates.map { .skipped($0, .infoRule) }
        }
        var glob: GlobPattern?
        var extensions: Set<String> = []
        var isChildren = false
        switch rule.match {
        case .measureOnly, .ownerCommand:
            return candidates.map { .skipped($0, .infoRule) }
        case .children:
            isChildren = true
        case .glob(let text):
            glob = GlobPattern(text)
        case .files(let wanted):
            extensions = Set(wanted.map { PathText.fold($0.hasPrefix(".") ? String($0.dropFirst()) : $0) })
        }

        let rootComponents = PathText.components(of: root)
        let siblings = indexedSiblings(siblingNames)
        let excluded = Set(rule.guards.excludeNames.map(PathText.fold))
        let minAge = rule.guards.minAge.map(seconds)
        var components: [[String]] = []
        var verdicts: [Verdict] = []
        components.reserveCapacity(candidates.count)
        verdicts.reserveCapacity(candidates.count)

        for candidate in candidates {
            let parts = PathText.components(of: candidate.url) ?? []
            components.append(parts)
            if candidate.depth < 1 || policy.isRoot(candidate.url, roots: [root]) {
                verdicts.append(.skip(.isRoot))
                continue
            }
            guard let rootParts = rootComponents, policy.isInside(candidate.url, roots: [root]) else {
                verdicts.append(.skip(.outsideRoots))
                continue
            }
            if policy.protectedReason(for: candidate.url) != nil {
                verdicts.append(.skip(.protectedPath))
                continue
            }
            let relative = Array(parts.dropFirst(rootParts.count))
            let fits = fitsShape(
                candidate, relative: relative, rule: rule,
                isChildren: isChildren, glob: glob, extensions: extensions
            )
            if !fits {
                verdicts.append(.notMatched)
                continue
            }
            if candidate.isSymlink && !isChildren {
                verdicts.append(.skip(.symlinkNotAllowed))
                continue
            }
            if relative.contains(where: { excluded.contains(PathText.fold($0)) }) {
                verdicts.append(.skip(.excludedName))
                continue
            }
            if !rule.guards.requiresSibling.isEmpty {
                let present = siblings[PathText.key(Array(parts.dropLast()))]
                let satisfied = present.map { names in
                    rule.guards.requiresSibling.contains(where: names.contains)
                } ?? false
                if !satisfied {
                    verdicts.append(.skip(.missingSibling))
                    continue
                }
            }
            if let minAge {
                guard let newest = candidate.newestModification else {
                    verdicts.append(.skip(.unknownAge))
                    continue
                }
                if env.now.timeIntervalSince(newest) <= minAge {
                    verdicts.append(.skip(.tooNew))
                    continue
                }
            }
            verdicts.append(.keep)
        }

        if let keep = rule.guards.keepNewest, keep > 0 {
            applyKeepNewest(keep, candidates: candidates, components: components, verdicts: &verdicts)
        }

        var outcomes: [MatchOutcome] = []
        for (index, candidate) in candidates.enumerated() {
            switch verdicts[index] {
            case .notMatched:
                continue
            case .skip(let reason):
                outcomes.append(.skipped(candidate, reason))
            case .keep:
                outcomes.append(.finding(finding(for: candidate, rule: rule)))
            }
        }
        return outcomes
    }

    // MARK: - Steps

    private static func fitsShape(
        _ candidate: Candidate,
        relative: [String],
        rule: Rule,
        isChildren: Bool,
        glob: GlobPattern?,
        extensions: Set<String>
    ) -> Bool {
        if isChildren { return candidate.depth == 1 }
        guard candidate.depth <= rule.depth else { return false }
        if let glob { return glob.matches(relative.map(PathText.fold)) }
        guard !candidate.isDirectory else { return false }
        return extensions.contains(PathText.fold(candidate.url.pathExtension))
    }

    private static func applyKeepNewest(
        _ keep: Int,
        candidates: [Candidate],
        components: [[String]],
        verdicts: inout [Verdict]
    ) {
        var groups: [String: [Int]] = [:]
        for index in candidates.indices {
            if case .keep = verdicts[index] {
                groups[PathText.key(Array(components[index].dropLast())), default: []].append(index)
            }
        }
        for indices in groups.values {
            let newestFirst = indices.sorted { lhs, rhs in
                switch (candidates[lhs].newestModification, candidates[rhs].newestModification) {
                case (nil, nil): return lhs < rhs
                case (nil, _): return true
                case (_, nil): return false
                case let (left?, right?): return left == right ? lhs < rhs : left > right
                }
            }
            for index in newestFirst.prefix(keep) {
                verdicts[index] = .skip(.keepNewest)
            }
        }
    }

    private static func finding(for candidate: Candidate, rule: Rule) -> Finding {
        Finding(
            ruleID: rule.id,
            url: candidate.url,
            fsid: candidate.fsid,
            fileID: candidate.fileID,
            allocatedBytes: candidate.allocatedBytes,
            privateBytes: candidate.privateBytes,
            newestModification: candidate.newestModification,
            isDirectory: candidate.isDirectory,
            isSymlink: candidate.isSymlink,
            flags: candidate.flags,
            itemCount: candidate.itemCount
        )
    }

    private static func indexedSiblings(_ siblingNames: [URL: Set<String>]) -> [String: Set<String>] {
        var indexed: [String: Set<String>] = [:]
        for (url, names) in siblingNames {
            guard let parts = PathText.components(of: url) else { continue }
            indexed[PathText.key(parts), default: []].formUnion(names)
        }
        return indexed
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }
}

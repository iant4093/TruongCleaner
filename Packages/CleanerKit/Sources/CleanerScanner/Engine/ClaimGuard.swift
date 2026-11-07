import CleanerCore
import Foundation

/// Decides when a finished rule's result may be delivered before the results of earlier rules.
///
/// When two rules find the same path, the earlier rule in the request keeps it (`ScanRequest.rules`).
/// So a finished rule normally has to wait for every rule before it. That holds back the whole list
/// behind one slow early rule. Most rules cannot find the same path at all, and for those the wait is
/// useless.
///
/// A path can be an item of rule A only if it lies inside a root of A, no deeper than A's depth below
/// that root. This guard knows those limits for every rule before any walk starts. A finished rule B may
/// be delivered at once when none of B's items is within the limits of an earlier rule that is still
/// unfinished. Then the earlier rule cannot offer any of B's paths, and the order of delivery cannot
/// change who keeps what.
struct ClaimGuard: Sendable {
    /// Where one rule may find items: its roots as folded path components, and how deep below them.
    private struct Space: Sendable {
        let roots: [[String]]
        let maxDepth: Int
    }

    private let spaces: [Space?]
    /// For each rule, the earlier rules whose roots lie in the same place (nested or equal).
    private let neighbours: [[Int]]

    /// - Parameters:
    ///   - rules: The rules of the request, in order.
    ///   - roots: The resolved roots of each rule, in the same order.
    init(rules: [Rule], roots: [RuleRoots]) {
        var spaces: [Space?] = []
        for (index, rule) in rules.enumerated() {
            guard RuleRoots.offersItems(rule), !roots[index].roots.isEmpty else {
                spaces.append(nil)
                continue
            }
            let depth: Int
            if case .children = rule.match { depth = 1 } else { depth = max(1, rule.depth) }
            spaces.append(Space(roots: roots[index].roots.map(Self.foldedComponents), maxDepth: depth))
        }
        self.spaces = spaces

        // roots by exact path, and every folder above a root, each pointing at the rules that own it
        var exact: [String: Set<Int>] = [:]
        var above: [String: Set<Int>] = [:]
        for (index, space) in spaces.enumerated() {
            guard let space else { continue }
            for root in space.roots {
                exact[Self.key(root), default: []].insert(index)
                for length in 1..<max(1, root.count) {
                    above[Self.key(Array(root.prefix(length))), default: []].insert(index)
                }
            }
        }
        var neighbours: [[Int]] = Array(repeating: [], count: spaces.count)
        for (index, space) in spaces.enumerated() {
            guard let space else { continue }
            var found = Set<Int>()
            for root in space.roots {
                // roots of other rules equal to this root or above it
                for length in 1...max(1, root.count) {
                    found.formUnion(exact[Self.key(Array(root.prefix(length)))] ?? [])
                }
                // roots of other rules below this root
                found.formUnion(above[Self.key(root)] ?? [])
            }
            neighbours[index] = found.filter { $0 < index && spaces[$0] != nil }.sorted()
        }
        self.neighbours = neighbours
    }

    /// True when rule `index` may be delivered now: no rule before it that is still `pending` could also
    /// offer one of `paths`.
    ///
    /// - Parameters:
    ///   - index: The finished rule.
    ///   - paths: The paths of its items.
    ///   - pending: Whether an earlier rule is not yet delivered.
    func mayDeliver(rule index: Int, paths: [URL], pending: (Int) -> Bool) -> Bool {
        let blockers = neighbours[index].filter(pending)
        if blockers.isEmpty { return true }
        if paths.isEmpty { return true }
        let folded = paths.map(Self.foldedComponents)
        for blocker in blockers {
            guard let space = spaces[blocker] else { continue }
            for path in folded where Self.couldOffer(space, path) { return false }
        }
        return true
    }

    private static func couldOffer(_ space: Space, _ path: [String]) -> Bool {
        for root in space.roots where path.count > root.count && path.count - root.count <= space.maxDepth {
            if path.starts(with: root) { return true }
        }
        return false
    }

    private static func key(_ components: [String]) -> String {
        components.joined(separator: "/")
    }

    private static func foldedComponents(_ url: URL) -> [String] {
        url.plainPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
    }
}

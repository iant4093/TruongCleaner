import CleanerCore
import Foundation

/// The concrete folders one rule walks, and what could not be resolved. Built once per scan so the
/// engine knows every rule's roots before it matches anything.
struct RuleRoots: Sendable {
    /// Most paths kept in each list.
    static let listCap = 50

    /// Real folders to walk, per starting folder and root spec, in name order.
    var roots: [URL] = []
    /// Folders macOS refused to open.
    var needsAccess: [URL] = []
    /// Roots that do not exist or are not real folders.
    var missing: [URL] = []
    /// Folders the rule leaves out on purpose (`Guards.excludeRootSegments`).
    var excluded: [URL] = []
    /// True when something was left out for a reason other than "missing" or "denied".
    var incomplete = false

    /// Whether the engine walks this rule at all. Owner commands and computed rows have no roots to walk.
    static func isWalked(_ rule: Rule) -> Bool {
        switch rule.match {
        case .ownerCommand, .computed: false
        default: true
        }
    }

    /// Whether the rule can produce findings. Info rules and measure-only rows only size their roots.
    static func offersItems(_ rule: Rule) -> Bool {
        guard rule.tier != .info else { return false }
        switch rule.match {
        case .children, .glob, .files: return true
        case .measureOnly, .ownerCommand, .computed: return false
        }
    }

    /// Resolves every root of `rule` against the file system. Reads only.
    static func resolve(_ rule: Rule, in environment: Environment) -> RuleRoots {
        var result = RuleRoots()
        guard isWalked(rule) else { return result }
        for spec in rule.roots {
            // One starting folder, or one per project folder the user chose.
            let starts = RootExpansion.starts(of: spec, in: environment)
            if starts.isEmpty && spec.base != .userChosen {
                // Unknown base (no Darwin directory): nothing is scanned.
                result.incomplete = true
                continue
            }
            for trusted in starts {
                guard let expanded = RootExpansion.expand(spec, from: trusted) else {
                    // An unsafe component: nothing is scanned.
                    result.incomplete = true
                    continue
                }
                let resolved = RootResolver.resolve(
                    expanded, trusted: trusted, excluding: rule.guards.excludeRootSegments)
                append(resolved.excluded, to: &result.excluded)
                append(resolved.needsAccess, to: &result.needsAccess)
                append(resolved.missing, to: &result.missing)
                result.incomplete = result.incomplete || resolved.incomplete
                for root in resolved.roots {
                    // The resolver already skips excluded wildcard folders; this is the same rule applied
                    // to the finished root, so a root can never be walked against the rule's patterns.
                    if rule.excludesRoot(root) {
                        append([root], to: &result.excluded)
                        continue
                    }
                    result.roots.append(root)
                }
            }
        }
        return result
    }

    private static func append(_ urls: [URL], to list: inout [URL]) {
        for url in urls where list.count < listCap && !list.contains(url) {
            list.append(url)
        }
    }
}

/// Finds items that hold the root of another rule.
///
/// When rule A offers `~/Library/Caches/com.apple.dt.Xcode` as one item and rule B walks that same
/// folder and offers what is inside, the same bytes would be offered twice. B is the more specific
/// rule, so it keeps its findings and A drops the item. Only rules that can produce findings count as
/// B: an Info row has nothing to offer, so it must not take items away from a rule that has.
///
/// Paths are compared by folded components (NFC, lowercase), because the volume does not tell
/// `Caches` from `caches` and a catalog name need not match the case on disk.
struct RootOverlap: Sendable {
    /// For a folded path that is a root of some rule, or lies above one: the IDs of those rules.
    private var owners: [String: Set<String>] = [:]

    /// - Parameters:
    ///   - rules: The rules to consider. A scan passes the whole catalog plus its own rules, enabled or not.
    ///   - roots: The resolved roots of each rule, in the same order.
    init(rules: [Rule], roots: [RuleRoots]) {
        for (index, rule) in rules.enumerated() where RuleRoots.offersItems(rule) {
            for root in roots[index].roots {
                var key = ""
                for part in Self.foldedComponents(root) {
                    key += "/" + part
                    owners[key, default: []].insert(rule.id)
                }
            }
        }
    }

    /// True when `url` equals or contains a root of a rule other than `ruleID`.
    func isCovered(_ url: URL, byRuleOtherThan ruleID: String) -> Bool {
        guard !owners.isEmpty else { return false }
        let key = "/" + Self.foldedComponents(url).joined(separator: "/")
        guard let found = owners[key] else { return false }
        return found.contains { $0 != ruleID }
    }

    private static func foldedComponents(_ url: URL) -> [String] {
        url.plainPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
    }
}

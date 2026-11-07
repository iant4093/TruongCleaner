import CleanerCore
import Foundation

/// The folder names a `.glob` rule lets the walker total as one node (`WalkOptions.pruneNames`).
///
/// A project artifact such as `node_modules` is offered as a whole, so the engine needs one node for
/// it, not one per entry inside. A name qualifies only when the glob ends in `**/<name>` for some
/// alternative: then every folder with that name, at any depth, is itself a match or lies inside one,
/// and nothing below it can be a separate match. Other endings (`*/*.xcarchive`, `.next/cache`) give no
/// names, so those rules keep the nodes they always did.
///
/// One consequence: a pruned name that appears where the glob does not match (for example directly in
/// the chosen folder, where `*/**/` needs one more level) hides matches below it. Fewer items are
/// offered, never more.
struct GlobPrune: Sendable, Equatable {
    /// Folded (NFC, lowercase) folder names to total as one node.
    var names: Set<String> = []
    /// Names of direct children of a pruned folder that still get a node, from `Guards.skipIfContains`.
    /// The matcher reads them to learn whether the folder holds one.
    var keepNames: Set<String> = []

    /// Most alternatives one `{a,b}` expansion may produce. Same limit as `GlobPattern`.
    private static let maxAlternatives = 256

    /// The prune settings for `rule`. Empty for rules that are not `.glob` and for Info rules.
    init(rule: Rule) {
        guard rule.tier != .info, case .glob(let text) = rule.match else { return }
        names = Self.names(forGlob: text)
        if !names.isEmpty {
            keepNames = Set(rule.guards.skipIfContains.map(Self.fold))
        }
    }

    /// Names a glob lets the walker prune. See the type comment.
    static func names(forGlob text: String) -> Set<String> {
        var names: Set<String> = []
        for alternative in alternatives(of: text) {
            let parts = alternative.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[parts.count - 2] == "**" else { continue }
            let last = parts[parts.count - 1]
            guard !last.contains(where: { "*{}".contains($0) }) else { continue }
            names.insert(fold(String(last)))
        }
        return names
    }

    /// Expands `{a,b}` groups the way `GlobPattern` does: the first `{` to the first `}` after it, only
    /// when the body has a comma. Anything else stays as written.
    static func alternatives(of text: String) -> [String] {
        var results: [String] = []
        var pending = [text]
        while let current = pending.popLast() {
            guard let open = current.firstIndex(of: "{"),
                  let close = current[open...].firstIndex(of: "}"),
                  current[current.index(after: open)..<close].contains(",")
            else {
                results.append(current)
                continue
            }
            let prefix = current[..<open]
            let suffix = current[current.index(after: close)...]
            let body = current[current.index(after: open)..<close]
            for option in body.split(separator: ",", omittingEmptySubsequences: false).reversed() {
                pending.append(String(prefix) + String(option) + String(suffix))
            }
            // Too many alternatives: stay with the pattern as written, which gives no names.
            if results.count + pending.count > maxAlternatives { return [text] }
        }
        return results
    }

    private static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}

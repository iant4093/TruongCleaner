import Foundation

// Pure helpers that relate a concrete root folder to the `RootSpec` values of a rule.
//
// A concrete root is what a scan or the gate holds: a real folder such as
// `/Users/me/Library/Containers/com.example.App/Data/Library/Caches`. The spec is
// `["Library", "Containers", "*", "Data", "Library", "Caches"]`. They are related by the
// spec's components alone: the last `components.count` path components of the folder must
// match the spec's components (a `*` matches any one name). The base is not compared, because
// the gate sees real paths (`/private/var/...`) while the spec says `darwinUserCache`.
// A spec without components therefore matches nothing. That only affects
// `.darwinCache()`/`.darwinTemp()` roots, which carry no owners and no wildcard.

extension RootSpec {
    /// The last `components.count` components of `root`, when they fit this spec. Nil otherwise.
    private func fittingTail(of root: URL) -> [String]? {
        guard !components.isEmpty, let parts = PathText.components(of: root),
            parts.count >= components.count
        else { return nil }
        let tail = Array(parts.suffix(components.count))
        for (pattern, name) in zip(components, tail)
        where !GlobPattern(pattern).matches([PathText.fold(name)]) {
            return nil
        }
        return tail
    }

    /// Whether a concrete folder is one this spec can stand for, judged by components only.
    public func matches(concreteRoot root: URL) -> Bool {
        fittingTail(of: root) != nil
    }

    /// The component of a concrete root that corresponds to component `index` of this spec.
    ///
    /// - Returns: nil when the root does not fit the spec or `index` is out of range.
    public func segment(at index: Int, inConcreteRoot root: URL) -> String? {
        guard index >= 0, index < components.count, let tail = fittingTail(of: root) else { return nil }
        return tail[index]
    }

    /// The folder names that the `*` components of this spec stand for in a concrete root.
    fileprivate func wildcardSegments(inConcreteRoot root: URL) -> [String]? {
        guard let tail = fittingTail(of: root) else { return nil }
        return zip(components, tail).filter { $0.0.contains("*") }.map(\.1)
    }
}

extension Rule {
    /// Owners that the roots add for items under `root`, from every root spec that fits it.
    ///
    /// When two specs fit the same folder their owners are combined, which can only make the
    /// rule stricter. The result has no duplicates and keeps the catalog order.
    public func rootOwners(for root: URL) -> [OwnerSpec] {
        var result: [OwnerSpec] = []
        for spec in roots where spec.matches(concreteRoot: root) {
            for owner in spec.owners where !result.contains(owner) {
                result.append(owner)
            }
        }
        return result
    }

    /// The name at component `index` of the root spec that `root` fits.
    ///
    /// - Returns: nil when no spec fits, or when the specs that fit disagree about the name
    ///   (compared without regard to case). Unknown means the caller keeps the item.
    public func rootSegment(at index: Int, in root: URL) -> String? {
        OwnerResolution.rootSegment(at: index, in: root, among: roots)
    }

    /// Whether `Guards.excludeRootSegments` leaves this concrete root out.
    ///
    /// Each pattern is matched against every folder name that a `*` of the fitting root spec
    /// stands for. A rule without `excludeRootSegments` never excludes a root.
    public func excludesRoot(_ root: URL) -> Bool {
        guard !guards.excludeRootSegments.isEmpty else { return false }
        let patterns = guards.excludeRootSegments.map { GlobPattern($0) }
        for spec in roots {
            guard let segments = spec.wildcardSegments(inConcreteRoot: root) else { continue }
            for segment in segments.map(PathText.fold) where patterns.contains(where: { $0.matches([segment]) }) {
                return true
            }
        }
        return false
    }
}

/// What an `OwnerSpec` means for one item.
public enum OwnerTarget: Sendable, Hashable {
    /// Ask a provider about this spec. It is a `.bundleID` or a `.processName`.
    case ask(OwnerSpec)
    /// The spec names no owner for this item (for example a folder that is not a bundle ID).
    case noOwner
    /// The owner cannot be worked out, so the caller keeps the item.
    case unresolvable
}

/// Reads owner specs that depend on where an item lies.
public enum OwnerResolution {
    /// The deepest of `roots` that contains `item` strictly below it, compared without regard to case.
    public static func deepestRoot(containing item: URL, in roots: [URL]) -> URL? {
        guard let itemParts = PathText.components(of: item).map({ $0.map(PathText.fold) }) else { return nil }
        var best: (url: URL, count: Int)?
        for root in roots {
            guard let rootParts = PathText.components(of: root).map({ $0.map(PathText.fold) }),
                itemParts.count > rootParts.count, itemParts.starts(with: rootParts)
            else { continue }
            if rootParts.count > (best?.count ?? -1) { best = (root, rootParts.count) }
        }
        return best?.url
    }

    /// Turns an owner spec into something a provider can answer.
    ///
    /// - Parameters:
    ///   - owner: The spec from a rule or root.
    ///   - item: The item about to be removed.
    ///   - root: The root the item lies under (see `deepestRoot(containing:in:)`), if known.
    ///   - rootSpecs: The rule's root specs, used to find which spec the root came from.
    public static func target(for owner: OwnerSpec, item: URL, root: URL?, rootSpecs: [RootSpec]) -> OwnerTarget {
        switch owner {
        case .bundleID, .processName:
            return .ask(owner)
        case .childNameAsBundleID(let suffix):
            guard let root, let itemParts = PathText.components(of: item),
                let rootParts = PathText.components(of: root), itemParts.count > rootParts.count
            else { return .unresolvable }
            return target(forName: itemParts[rootParts.count], stripSuffix: suffix)
        case .rootSegmentAsBundleID(let index):
            guard let root, let name = rootSegment(at: index, in: root, among: rootSpecs) else { return .unresolvable }
            return target(forName: name, stripSuffix: nil)
        }
    }

    /// A folder name read as a bundle identifier: at least three dot-separated parts, none empty.
    ///
    /// - Parameters:
    ///   - name: The folder name.
    ///   - stripSuffix: Removed from the end first (without regard to case) when present.
    /// - Returns: The bundle ID, or nil when the name does not look like one.
    public static func bundleID(fromName name: String, stripSuffix: String?) -> String? {
        var text = name
        if let suffix = stripSuffix, !suffix.isEmpty,
            let range = text.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards])
        {
            text.removeSubrange(range)
        }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count >= 3, !pieces.contains(where: \.isEmpty) else { return nil }
        return text
    }

    /// The name at component `index` of the spec in `specs` that `root` fits. Nil when none fits
    /// or the ones that fit disagree.
    static func rootSegment(at index: Int, in root: URL, among specs: [RootSpec]) -> String? {
        var found: [String] = []
        for spec in specs {
            if let name = spec.segment(at: index, inConcreteRoot: root) { found.append(name) }
        }
        guard let first = found.first,
            found.allSatisfy({ PathText.fold($0) == PathText.fold(first) })
        else { return nil }
        return first
    }

    private static func target(forName name: String, stripSuffix: String?) -> OwnerTarget {
        guard let id = bundleID(fromName: name, stripSuffix: stripSuffix) else { return .noOwner }
        return .ask(.bundleID(id))
    }
}

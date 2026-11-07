import Foundation

/// Pure decisions about paths: what is protected, what is inside a root, what is a root.
///
/// No method touches the file system. Callers pass URLs whose parent's real path
/// is already resolved; `.` and `..` are resolved lexically here. A URL that is not
/// an absolute file URL is never inside a root and is treated as protected.
///
/// Comparison rules, all on whole path components (never string prefixes):
/// - `protectedReason` and `isRoot` ignore case, so `~/library/MAIL` is still Mail's folder.
/// - `isInside` is case-sensitive, so a differently-cased path is not offered.
/// - `protectedReason` and `isRoot` read `/System/Volumes/Data/Users/x` like `/Users/x`.
public struct PathPolicy: Sendable {
    private struct CompiledEntry: Sendable {
        let pattern: GlobPattern
        let exceptions: [GlobPattern]
        let reason: ProtectedReason
    }

    private let homeFolded: [String]
    private let entries: [CompiledEntry]
    private let exclusions: [[String]]

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - environment: Supplies the home folder that `~` in the protected list means.
    ///   - userExclusions: Folders the user excluded in Settings.
    public init(environment: Environment, userExclusions: [URL]) {
        let homeComponents = PathText.components(of: environment.home).map(PathText.canonical) ?? []
        homeFolded = homeComponents.map(PathText.fold)
        entries = ProtectedList.entries.map { entry in
            var exceptions: [GlobPattern] = []
            if entry.pattern.hasSuffix("/**") {
                let prefix = String(entry.pattern.dropLast(3))
                exceptions = entry.exceptions.map {
                    GlobPattern(prefix + "/" + $0 + "/**", home: homeComponents)
                }
            }
            return CompiledEntry(
                pattern: GlobPattern(entry.pattern, home: homeComponents),
                exceptions: exceptions,
                reason: entry.reason
            )
        }
        exclusions = userExclusions.compactMap { url in
            PathText.components(of: url).map { PathText.canonical($0).map(PathText.fold) }
        }
    }

    /// Why a path must never be offered, or nil when no protected row covers it.
    ///
    /// A user exclusion also protects every folder that contains it, because
    /// removing the parent would remove the excluded folder.
    public func protectedReason(for url: URL) -> ProtectedReason? {
        guard let raw = PathText.components(of: url) else { return .root }
        let path = PathText.canonical(raw).map(PathText.fold)
        for exclusion in exclusions
        where path.starts(with: exclusion) || exclusion.starts(with: path) {
            return .userExcluded
        }
        for entry in entries
        where entry.pattern.matches(path) && !entry.exceptions.contains(where: { $0.matches(path) }) {
            return entry.reason
        }
        return nil
    }

    /// Whether `url` is one of `roots` or lies below one, compared component by component.
    public func isInside(_ url: URL, roots: [URL]) -> Bool {
        guard let path = PathText.components(of: url) else { return false }
        return roots.contains { root in
            guard let rootPath = PathText.components(of: root) else { return false }
            return path.starts(with: rootPath)
        }
    }

    /// Whether `url` is a folder we never delete itself: one of `roots`, `~`,
    /// `~/Library`, `/`, `/Applications`, `/Library`, `/Users` or `/Users/Shared`.
    /// An unusable URL counts as a root, so it is kept.
    public func isRoot(_ url: URL, roots: [URL]) -> Bool {
        guard let raw = PathText.components(of: url) else { return true }
        let path = PathText.canonical(raw).map(PathText.fold)
        let wellKnown: [[String]] = [
            [], ["applications"], ["library"], ["users"], ["users", "shared"],
            homeFolded, homeFolded + ["library"],
        ]
        if wellKnown.contains(path) { return true }
        return roots.contains { root in
            guard let rootPath = PathText.components(of: root) else { return false }
            return PathText.canonical(rootPath).map(PathText.fold) == path
        }
    }
}
